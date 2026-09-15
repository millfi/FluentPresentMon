#include <windows.h>
#include <appmodel.h>
#include <wincrypt.h>

#include <fstream>
#include <iomanip>
#include <iostream>
#include <iterator>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

#pragma comment(lib, "crypt32.lib")
#pragma comment(lib, "kernel32.lib")

namespace {

std::runtime_error MakeWin32Error(const char* operation, DWORD status)
{
    std::ostringstream message;
    message << operation << " failed with Win32 error " << status;
    return std::runtime_error(message.str());
}

std::wstring GetFamilyName(const std::wstring& name, const std::wstring& publisher)
{
    PACKAGE_ID packageId{};
    packageId.processorArchitecture = PROCESSOR_ARCHITECTURE_AMD64;
    packageId.name = const_cast<PWSTR>(name.c_str());
    packageId.publisher = const_cast<PWSTR>(publisher.c_str());
    wchar_t resourceId[] = L"";
    packageId.resourceId = resourceId;

    UINT32 length = 0;
    LONG status = PackageFamilyNameFromId(&packageId, &length, nullptr);
    if (status != ERROR_INSUFFICIENT_BUFFER) {
        throw MakeWin32Error("PackageFamilyNameFromId", (DWORD)status);
    }

    std::vector<wchar_t> buffer(length);
    status = PackageFamilyNameFromId(&packageId, &length, buffer.data());
    if (status != ERROR_SUCCESS) {
        throw MakeWin32Error("PackageFamilyNameFromId", (DWORD)status);
    }
    return std::wstring(buffer.data());
}

std::string GetCertificateSignatureHash(const std::wstring& path)
{
    std::ifstream input(path, std::ios::binary);
    if (!input) {
        throw std::runtime_error("Unable to open certificate file.");
    }
    std::vector<BYTE> encoded(
        (std::istreambuf_iterator<char>(input)),
        std::istreambuf_iterator<char>());
    if (encoded.empty()) {
        throw std::runtime_error("Certificate file is empty.");
    }

    PCCERT_CONTEXT certificate = CertCreateCertificateContext(
        X509_ASN_ENCODING | PKCS_7_ASN_ENCODING,
        encoded.data(),
        (DWORD)encoded.size());
    if (!certificate) {
        throw MakeWin32Error("CertCreateCertificateContext", GetLastError());
    }

    try {
        DWORD size = 0;
        if (!CertGetCertificateContextProperty(
                certificate,
                CERT_SIGNATURE_HASH_PROP_ID,
                nullptr,
                &size)) {
            throw MakeWin32Error("CertGetCertificateContextProperty", GetLastError());
        }
        if (size != 32) {
            throw std::runtime_error("SCCD requires a certificate with a SHA-256 signature hash.");
        }

        std::vector<BYTE> hash(size);
        if (!CertGetCertificateContextProperty(
                certificate,
                CERT_SIGNATURE_HASH_PROP_ID,
                hash.data(),
                &size)) {
            throw MakeWin32Error("CertGetCertificateContextProperty", GetLastError());
        }

        std::ostringstream result;
        result << std::hex << std::setfill('0');
        for (BYTE value : hash) {
            result << std::setw(2) << (unsigned)value;
        }
        CertFreeCertificateContext(certificate);
        return result.str();
    }
    catch (...) {
        CertFreeCertificateContext(certificate);
        throw;
    }
}

void PrintUsage()
{
    std::wcerr << L"Usage:\n"
                  L"  PresentMonMsixIdentity.exe family-name <name> <publisher>\n"
                  L"  PresentMonMsixIdentity.exe signature-hash <certificate-file>\n";
}

}

int wmain(int argc, wchar_t** argv)
{
    if (argc == 4 && std::wstring(argv[1]) == L"family-name") {
        try {
            std::wcout << GetFamilyName(argv[2], argv[3]) << L'\n';
            return 0;
        }
        catch (const std::exception& error) {
            std::cerr << error.what() << '\n';
            return 1;
        }
    }
    if (argc == 3 && std::wstring(argv[1]) == L"signature-hash") {
        try {
            std::cout << GetCertificateSignatureHash(argv[2]) << '\n';
            return 0;
        }
        catch (const std::exception& error) {
            std::cerr << error.what() << '\n';
            return 1;
        }
    }
    PrintUsage();
    return 2;
}
