# Third-party playback engine

FamilyTV dynamically embeds the official VideoLAN VLCKit 3.7.3 binary framework,
including its libVLC playback engine and bundled codecs/modules. The complete
framework is retained with its resources and symlinks. No Homebrew or installed
VLC application is required on the user's Mac.

- VLCKit: GNU LGPL version 2.1 or later; see LICENSE-VLCKit.txt.
- VLCKit source corresponding to this package: https://code.videolan.org/videolan/VLCKit/-/tree/319ed2c0
- libVLC source corresponding to this package: https://code.videolan.org/videolan/vlc/-/tree/79128878
- Official binary: https://download.videolan.org/pub/cocoapods/prod/VLCKit-3.7.3-319ed2c0-79128878.tar.xz
- VideoLAN licensing details and bundled dependency licenses: https://www.videolan.org/legal.html

The application is ad-hoc signed without hardened library validation. A modified
compatible VLCKit.framework may replace Contents/Frameworks/VLCKit.framework;
the app and modified framework then need to be ad-hoc signed again. FamilyTV
does not alter or conceal the playback engine's source or license notices.
