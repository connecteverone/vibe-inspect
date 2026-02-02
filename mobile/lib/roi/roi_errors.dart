enum RoiErrorCode {
  invalidPayload,
  missingPayload,
  unsupportedAction,
  roiQuicPortBusy,
  roiQuicPortUnavailable,
  unknown,
}

RoiErrorCode roiErrorCodeFromString(String? code) {
  switch (code) {
    case 'invalid_payload':
      return RoiErrorCode.invalidPayload;
    case 'missing_payload':
      return RoiErrorCode.missingPayload;
    case 'unsupported_action':
      return RoiErrorCode.unsupportedAction;
    case 'roi_quic_port_busy':
      return RoiErrorCode.roiQuicPortBusy;
    case 'roi_quic_port_unavailable':
      return RoiErrorCode.roiQuicPortUnavailable;
    default:
      return RoiErrorCode.unknown;
  }
}

String roiErrorCodeToString(RoiErrorCode code) {
  switch (code) {
    case RoiErrorCode.invalidPayload:
      return 'invalid_payload';
    case RoiErrorCode.missingPayload:
      return 'missing_payload';
    case RoiErrorCode.unsupportedAction:
      return 'unsupported_action';
    case RoiErrorCode.roiQuicPortBusy:
      return 'roi_quic_port_busy';
    case RoiErrorCode.roiQuicPortUnavailable:
      return 'roi_quic_port_unavailable';
    case RoiErrorCode.unknown:
      return 'unknown';
  }
}
