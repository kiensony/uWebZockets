# Third-Party Notices

µWebZockets includes or links the following third-party software:

| Component | Version or revision | License |
| --- | --- | --- |
| zslay | 0.1.5 | MIT |
| libxev | 9ce8e8e6ff89e583258a7f8e7adeeeaeae8611bf | MIT |
| BoringSSL | 7c1efd8d6ffb36a57feba44e8c73cf674801f3cb | ISC-style and component licenses |
| lsquic | 4.9.3 | MIT and bundled component licenses |
| libdeflate | 1.26 | MIT |
| zlib | system-provided | zlib License |
| h1spec | f0a5650a20c575fbea0f7179a3a9cfa50f20ba6e | MIT |

The zslay and libxev license texts are in the licenses directory. Vendored
projects retain their license files under vendor. Binary release archives copy
every license needed by the included static libraries into licenses/vendor.
zlib is linked from the target toolchain and is not copied into release
archives; downstream applications must satisfy its license and linkage terms.
