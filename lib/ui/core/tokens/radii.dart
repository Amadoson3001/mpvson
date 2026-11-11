/// Corner radius scale. Pick by role, never by pixel value.
abstract final class AppRadii {
  static const double square = 0;

  /// Buttons, inputs, nav items, chips.
  static const double control = 8;

  /// Cards, tiles, artwork, banners, menus.
  static const double artwork = 12;

  /// Modal dialogs.
  static const double dialog = 12;

  /// Modern container and card radius.
  static const double card = 16;

  /// Hero artwork such as the Now Playing cover.
  static const double artworkHero = 24;

  /// Fully rounded ends for pills and badges.
  static const double pill = 999;
}
