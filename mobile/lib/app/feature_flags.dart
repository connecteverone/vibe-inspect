part of '../main.dart';

const bool kEnableLegacyVnc =
    bool.fromEnvironment('ENABLE_LEGACY_VNC', defaultValue: false);
const bool kEnableRemoteControl = true;
const bool kDirectOnly =
    bool.fromEnvironment('DIRECT_ONLY', defaultValue: true);
