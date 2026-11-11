libmpv-2.dll with full FFmpeg (dynaudnorm, acompressor, alimiter, loudnorm), replacing media_kit's stripped build
on Windows so volume leveling works. Not in git (~122 MB): windows\fetch_libmpv.ps1 downloads and verifies it here,
and windows\CMakeLists.txt runs that script at configure time and installs the DLL over media_kit's copy.

Source:  https://github.com/shinchiro/mpv-winbuild-cmake/releases/tag/20261111 (the builds linked from mpv.io)
Archive: mpv-dev-x86_64-20261111-git-bcde6b93cc.7z (mpv git bcde6b93cc, client API 2.6; media_kit's was 2.1)
  SHA256 273C079B11EA5575822F972756F4C9A71149A5C10130353ABEB8586738938452 (matches GitHub's published asset digest)
DLL SHA256 88504EE5560942A955405E99DFB5971368E4CF851321F36565BF2A667271DB1B (121,789,952 bytes)
License: GPL build (mpv + FFmpeg GPL). shinchiro prunes old releases: a backup of the .7z is kept outside git;
copy it into this folder and the script uses it instead of downloading.
