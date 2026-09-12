import QtQuick
import qs.Commons

// Shared reader header: prev/next buttons flanking a centered column of
// title, subtitle, and a PositionBar. The Bible reader additionally shows a
// trailing ☰ books button (showExtraButton); the center column width shrinks
// by that button's width plus one extra spacing only when it is present.
Row {
  id: readerHeader
  width: parent.width
  spacing: Style.spacing.sm

  required property color barForeground
  required property color foreground
  required property string fontFamily
  required property Item keyCatcher

  property string title: ""
  property string subtitle: ""
  property int positionValue: 0
  property int positionMax: 0
  property string positionLabelPrefix: ""
  // Extra trailing button (the Bible's ☰ books button); hidden for the
  // two-button reader header.
  property bool showExtraButton: false
  property bool extraButtonActive: false
  // Strong's numbers toggle (KJV reader only); a second trailing button
  // after the ☰ books button. The Bible panel wires it to the
  // strongsNumbers state.
  property bool showStrongsButton: false
  property bool strongsButtonActive: false

  signal jump(int target)
  signal prev()
  signal next()
  signal extraClicked()
  signal strongsClicked()

  NavButton {
    id: prevButton
    barForeground: readerHeader.barForeground
    foreground: readerHeader.foreground
    fontFamily: readerHeader.fontFamily
    glyph: "◀"
    large: true
    onClicked: readerHeader.prev()
  }

  Column {
    width: readerHeader.width - prevButton.width - nextButton.width
      - (readerHeader.showExtraButton ? extraButton.width + readerHeader.spacing : 0)
      - (readerHeader.showStrongsButton ? strongsButton.width + readerHeader.spacing : 0)
      - readerHeader.spacing * 2
    spacing: Style.spacing.sm

    Text {
      width: parent.width
      text: readerHeader.title
      textFormat: Text.PlainText
      color: readerHeader.foreground
      font.family: readerHeader.fontFamily
      font.pixelSize: Style.font.subtitle
      font.bold: true
      horizontalAlignment: Text.AlignHCenter
      wrapMode: Text.Wrap
      maximumLineCount: 2
      elide: Text.ElideRight

      // Plain Text is mouse-transparent, so a click here falls through to
      // bodyScroll, which grabs it for drag detection and leaves the search
      // field focused. TapHandler is passive, so it clears focus without
      // stealing the Flickable's drag gesture.
      TapHandler {
        onTapped: readerHeader.keyCatcher.forceActiveFocus()
      }
    }

    Text {
      width: parent.width
      text: readerHeader.subtitle
      textFormat: Text.PlainText
      color: Color.muted
      font.family: readerHeader.fontFamily
      font.pixelSize: Style.font.caption
      horizontalAlignment: Text.AlignHCenter
      elide: Text.ElideRight

      TapHandler {
        onTapped: readerHeader.keyCatcher.forceActiveFocus()
      }
    }

    PositionBar {
      value: readerHeader.positionValue
      max: readerHeader.positionMax
      labelPrefix: readerHeader.positionLabelPrefix
      foreground: readerHeader.foreground
      fontFamily: readerHeader.fontFamily
      onJump: function(target) { readerHeader.jump(target) }
    }
  }

  NavButton {
    id: nextButton
    barForeground: readerHeader.barForeground
    foreground: readerHeader.foreground
    fontFamily: readerHeader.fontFamily
    glyph: "▶"
    large: true
    onClicked: readerHeader.next()
  }

  NavButton {
    id: extraButton
    barForeground: readerHeader.barForeground
    foreground: readerHeader.foreground
    fontFamily: readerHeader.fontFamily
    visible: readerHeader.showExtraButton
    glyph: "☰"
    large: true
    active: readerHeader.extraButtonActive
    onClicked: readerHeader.extraClicked()
  }

  // Strong's numbers toggle; the active state (accent color + fill) marks
  // "numbers visible".
  NavButton {
    id: strongsButton
    barForeground: readerHeader.barForeground
    foreground: readerHeader.foreground
    fontFamily: readerHeader.fontFamily
    visible: readerHeader.showStrongsButton
    glyph: "S"
    large: true
    active: readerHeader.strongsButtonActive
    onClicked: readerHeader.strongsClicked()
  }
}
