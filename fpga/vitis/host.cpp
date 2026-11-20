#include <xrt/xrt_bo.h>
#include <xrt/xrt_device.h>
#if __has_include(<xrt/experimental/xrt_ip.h>)
#include <xrt/experimental/xrt_ip.h>
#include <xrt/experimental/xrt_xclbin.h>
#else
#include <experimental/xrt_ip.h>
#include <experimental/xrt_xclbin.h>
#endif

#include <algorithm>
#include <cerrno>
#include <charconv>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <fcntl.h>
#include <iomanip>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <string>
#include <string_view>
#include <sys/stat.h>
#include <system_error>
#include <thread>
#include <unistd.h>

namespace {
using Clock = std::chrono::steady_clock;
constexpr std::size_t alignment = 4096;
constexpr std::size_t record_bytes = 16;
constexpr std::uint32_t control = 0x00, base_lo = 0x10, base_hi = 0x14, records = 0x18;
constexpr std::uint32_t match_lo = 0x20, match_hi = 0x24, checksum = 0x28;
constexpr std::uint32_t done = 1, fault = 2, busy = 4;

class InputFile {
public:
    explicit InputFile(const char* path) : handle(open(path, O_RDONLY | O_CLOEXEC | O_DIRECT)) {
        if (handle == -1) throw std::system_error(errno, std::generic_category(), "open O_DIRECT");
    }
    ~InputFile() { close(handle); }
    InputFile(const InputFile&) = delete;
    InputFile& operator=(const InputFile&) = delete;

    std::uint64_t size() const {
        struct stat info {};
        if (fstat(handle, &info) != 0) throw std::system_error(errno, std::generic_category(), "fstat");
        if (!S_ISREG(info.st_mode) || info.st_size <= 0 || info.st_size % alignment != 0)
            throw std::runtime_error("Use a nonempty regular dataset file whose size is a multiple of 4096 bytes");
        return static_cast<std::uint64_t>(info.st_size);
    }

    void read_into(char* destination, std::size_t length) const {
        if (!destination || reinterpret_cast<std::uintptr_t>(destination) % alignment != 0)
            throw std::runtime_error("XRT did not provide a 4096-byte-aligned P2P mapping");
        constexpr std::size_t chunk = 8 * 1024 * 1024;
        for (std::size_t position = 0; position < length;) {
            const auto n = pread(handle, destination + position, std::min(chunk, length - position),
                                 static_cast<off_t>(position));
            if (n < 0 && errno == EINTR) continue;
            if (n < 0) throw std::system_error(errno, std::generic_category(), "NVMe-to-HBM direct read");
            if (n == 0 || n % alignment != 0) throw std::runtime_error("Incomplete aligned direct read");
            position += static_cast<std::size_t>(n);
        }
    }

private:
    int handle;
};

template<class T>
T parse_unsigned(std::string_view text) {
    T result = 0;
    const auto parsed = std::from_chars(text.data(), text.data() + text.size(), result);
    if (parsed.ec != std::errc{} || parsed.ptr != text.data() + text.size())
        throw std::invalid_argument("Expected an unsigned decimal argument");
    return result;
}

double seconds(Clock::duration duration) {
    return std::chrono::duration<double>(duration).count();
}
}

int main(int argc, char** argv) try {
    if (argc != 5 && argc != 6) {
        std::cerr << "Usage: dataset_scan_host <xclbin> <records.bin> <expected-matches> <expected-checksum> [device-index]\n";
        return 2;
    }
    const auto expected_matches = parse_unsigned<std::uint64_t>(argv[3]);
    const auto expected_checksum = parse_unsigned<std::uint32_t>(argv[4]);
    const auto device_index = argc == 6 ? parse_unsigned<unsigned>(argv[5]) : 0u;
    const InputFile input(argv[2]);
    const auto bytes = input.size();
    if (bytes > std::numeric_limits<std::size_t>::max() ||
        bytes / record_bytes > std::numeric_limits<std::uint32_t>::max())
        throw std::runtime_error("Dataset exceeds the addressable scan size");
    const auto count = static_cast<std::uint32_t>(bytes / record_bytes);

    auto device = xrt::device(device_index);
    const xrt::xclbin binary{std::string(argv[1])};
    const auto uuid = device.load_xclbin(binary);
    auto ip = xrt::ip(device, uuid, "dataset_scan:{dataset_scan_1}");
    const auto banks = binary.get_mems();
    const auto bank = std::find_if(banks.begin(), banks.end(), [](const auto& memory) {
        return memory.get_used() && memory.get_tag() == "HBM[0]";
    });
    if (bank == banks.end() || bank->get_index() < 0 || bytes / 1024 > bank->get_size_kb())
        throw std::runtime_error("The dataset does not fit a connected HBM[0] bank");
    auto buffer = xrt::bo(device, static_cast<std::size_t>(bytes), xrt::bo::flags::p2p, bank->get_index());
    auto destination = buffer.map<char*>();
    const auto address = buffer.address();
    if (address % alignment != 0) throw std::runtime_error("HBM address is not 4096-byte aligned");
    if (ip.read_register(control) & busy) throw std::runtime_error("Scan engine is busy");

    const auto start = Clock::now();
    input.read_into(destination, static_cast<std::size_t>(bytes));
    const auto staged = Clock::now();
    ip.write_register(base_lo, static_cast<std::uint32_t>(address));
    ip.write_register(base_hi, static_cast<std::uint32_t>(address >> 32));
    ip.write_register(records, count);
    ip.write_register(control, 1);
    const auto deadline = staged + std::chrono::seconds(30);
    std::uint32_t status = 0;
    for (;;) {
        status = ip.read_register(control);
        if (status & done) break;
        if (Clock::now() >= deadline) throw std::runtime_error("Scan timed out. Reset the compute unit before reusing it.");
        std::this_thread::sleep_for(std::chrono::microseconds(20));
    }
    if (status & fault) throw std::runtime_error("Scan reported an AXI or argument fault");
    const auto matches = (static_cast<std::uint64_t>(ip.read_register(match_hi)) << 32) | ip.read_register(match_lo);
    const auto sum = ip.read_register(checksum);
    const auto finished = Clock::now();
    if (matches != expected_matches || sum != expected_checksum)
        throw std::runtime_error("Result mismatch: matches=" + std::to_string(matches) + " checksum=" + std::to_string(sum));

    std::cout << "Records " << count << ", matches " << matches << ", checksum " << sum << '\n'
              << "Staged " << bytes << " bytes into P2P HBM; result payload 12 bytes plus control traffic\n"
              << std::fixed << std::setprecision(3)
              << "Stage " << 1000 * seconds(staged - start) << " ms, scan and readback "
              << 1000 * seconds(finished - staged) << " ms, total " << 1000 * seconds(finished - start)
              << " ms, " << count / seconds(finished - start) << " records/s\n";
    return 0;
} catch (const std::exception& error) {
    std::cerr << error.what() << '\n';
    return 1;
}
