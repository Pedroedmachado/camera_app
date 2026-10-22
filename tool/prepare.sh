#!/usr/bin/env bash
# Gera as pastas android/ e windows/ do Flutter e ajusta permissões e nome.
set -euo pipefail

flutter create --org br.camlivre --project-name camlivre --platforms=android,windows .
rm -rf test

M=android/app/src/main/AndroidManifest.xml
if [ -f "$M" ]; then
  if ! grep -q 'android.permission.INTERNET' "$M"; then
    sed -i 's#<manifest xmlns:android="http://schemas.android.com/apk/res/android">#&\n    <uses-permission android:name="android.permission.INTERNET"/>\n    <uses-permission android:name="android.permission.ACCESS_NETWORK_STATE"/>\n    <uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE" android:maxSdkVersion="29"/>#' "$M"
  fi
  grep -q 'android.permission.INTERNET' "$M" || { echo "Falha ao adicionar permissão INTERNET"; exit 1; }
  sed -i 's#android:label="camlivre"#android:label="CamLivre"#' "$M"
fi

W=windows/runner/main.cpp
if [ -f "$W" ]; then
  sed -i 's#L"camlivre"#L"CamLivre"#' "$W"
fi

echo "Preparo concluído."
