flutter_inappwebview_android 1.1.3 (Apache-2.0, pub.dev), copied unchanged except android/build.gradle:
the debug/release proguardFiles lines (getDefaultProguardFile('proguard-android.txt')) were removed and the
library's own release minify turned off, because AGP 9 refuses to evaluate that file. Drop this folder and the
dependency_overrides entry in pubspec.yaml once a stable flutter_inappwebview release fixes it (1.2.0-beta does,
but needs the whole 6.2.0-beta family).
