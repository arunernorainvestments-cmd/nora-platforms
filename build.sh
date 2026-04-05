#!/bin/bash
set -e
echo "Installing Flutter..."
git clone https://github.com/flutter/flutter.git -b stable /tmp/flutter --depth 1
export PATH="$PATH:/tmp/flutter/bin"
echo "Flutter installed, getting packages..."
cd flutter_app
flutter pub get
echo "Building web..."
flutter build web --release --no-tree-shake-icons
echo "Done!"
