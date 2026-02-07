enum TrackpadScrollMode { followHost, natural, classic }

class TrackpadScrollBehavior {
  const TrackpadScrollBehavior({
    this.mode = TrackpadScrollMode.followHost,
    this.hostNaturalScroll,
  });

  final TrackpadScrollMode mode;
  final bool? hostNaturalScroll;

  bool get _invertDelta {
    switch (mode) {
      case TrackpadScrollMode.followHost:
        return hostNaturalScroll ?? false;
      case TrackpadScrollMode.natural:
        return true;
      case TrackpadScrollMode.classic:
        return false;
    }
  }

  double transformDeltaY(double deltaY) {
    return _invertDelta ? -deltaY : deltaY;
  }
}
