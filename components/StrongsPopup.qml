import QtQuick
import qs.Commons

// Strong's definition card. Rendered as an overlay on the panel's keyCatcher
// (same approach as InPanelDropdown: a QQC.Popup inside the layer-shell
// panel conflicts with the surface on first show and hangs it open). Shows
// the number, original-language lemma, transliteration/pronunciation,
// derivation, Strong's definition, and KJV renderings for one entry.
Item {
  id: popup

  required property color barForeground
  required property color foreground
  required property string fontFamily
  // Content root the card overlays (the panel's keyCatcher).
  required property Item keyCatcher
  // The hosting panel: the card closes on tab switch / panel close.
  required property QtObject panel

  // The dictionary entry object ({lemma, xlit, pron, derivation,
  // strongs_def, kjv_def}) or null when the number has no entry.
  property var entry: null
  // The Strong's number being shown ("H3068" / "G26"), for the header and
  // for the entry-missing fallback.
  property string number: ""
  // Language label derived from the number prefix.
  readonly property string language: number.charAt(0) === "H" ? "Hebrew" : "Greek"

  signal closed()

  readonly property bool popupOpen: card.visible

  function open() {
    card.visible = true
  }

  function close() {
    card.visible = false
    closed()
  }

  readonly property real opacitySecondary: 0.62

  // ---- overlay card -------------------------------------------------------

  Rectangle {
    id: card
    parent: popup.keyCatcher
    z: 110 // above the translation dropdown's option list (z: 100)
    visible: false
    width: Math.min(popup.keyCatcher.width - Style.spacing.lg * 2, Style.space(360))
    height: cardColumn.implicitHeight + Style.spacing.lg * 2
    x: (popup.keyCatcher.width - width) / 2
    y: Math.max(Style.spacing.lg,
      Math.min(popup.keyCatcher.height - height - Style.spacing.lg,
        (popup.keyCatcher.height - height) / 2))
    radius: Style.cornerRadius
    color: Color.popups.background
    border.width: 1
    border.color: Color.popups.border

    Column {
      id: cardColumn
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.margins: Style.spacing.lg
      spacing: Style.spacing.sm

      // Header row: number + language label, close button on the right.
      Row {
        width: parent.width
        spacing: Style.spacing.sm

        Text {
          id: numberLabel
          text: popup.number + "  ·  " + popup.language
          textFormat: Text.PlainText
          color: Color.accent
          font.family: popup.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.bold: true
          anchors.verticalCenter: parent.verticalCenter
          elide: Text.ElideRight
          width: parent.width - closeButton.width - parent.spacing
        }

        Rectangle {
          id: closeButton
          anchors.verticalCenter: parent.verticalCenter
          width: Style.spacing.controlHeight
          height: Style.spacing.controlHeight
          radius: Style.cornerRadius
          color: closeMouse.containsMouse
            ? Style.hoverFillFor(popup.barForeground, Color.accent)
            : "transparent"

          Text {
            anchors.centerIn: parent
            text: "✕"
            textFormat: Text.PlainText
            color: popup.foreground
            font.family: popup.fontFamily
            font.pixelSize: Style.font.caption
          }

          MouseArea {
            id: closeMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: popup.close()
          }
        }
      }

      // Lemma in the original script, large, with transliteration +
      // pronunciation underneath.
      Text {
        visible: popup.entry !== null
        width: parent.width
        text: popup.entry ? popup.entry.lemma : ""
        textFormat: Text.PlainText
        color: popup.foreground
        font.family: popup.fontFamily
        font.pixelSize: Style.font.heading
        horizontalAlignment: Text.AlignRight
        wrapMode: Text.WordWrap
      }

      Text {
        id: pronText
        visible: popup.entry !== null && text !== ""
        width: parent.width
        text: {
          if (!popup.entry) return ""
          var parts = []
          if (popup.entry.xlit) parts.push(popup.entry.xlit)
          if (popup.entry.pron) parts.push("<" + popup.entry.pron + ">")
          return parts.join("  ")
        }
        textFormat: Text.PlainText
        color: popup.foreground
        opacity: popup.opacitySecondary
        font.family: popup.fontFamily
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.WordWrap
      }

      Rectangle {
        visible: popup.entry !== null
        width: parent.width
        height: 1
        color: Util.alpha(popup.barForeground, 0.10)
      }

      // Definition sections; each label/value pair renders only when present.
      Repeater {
        model: {
          var e = popup.entry
          if (!e) return []
          var out = []
          if (e.derivation) out.push({ label: "Derivation", value: e.derivation })
          if (e.strongs_def) out.push({ label: "Strong's", value: e.strongs_def })
          if (e.kjv_def) out.push({ label: "KJV renderings", value: e.kjv_def })
          return out
        }

        delegate: Column {
          required property var modelData
          width: cardColumn.width
          spacing: Style.spacing.xxs

          Text {
            width: parent.width
            text: modelData.label
            textFormat: Text.PlainText
            color: Color.muted
            font.family: popup.fontFamily
            font.pixelSize: Style.font.caption
            font.letterSpacing: 0.6
          }

          Text {
            width: parent.width
            text: modelData.value
            textFormat: Text.PlainText
            color: popup.foreground
            font.family: popup.fontFamily
            font.pixelSize: Style.font.bodySmall
            lineHeight: 1.4
            wrapMode: Text.WordWrap
          }
        }
      }

      // Fallback for a number without a dictionary entry (should not happen —
      // the converter verifies every tag — but the reader stays defensive).
      Text {
        visible: popup.entry === null
        width: parent.width
        text: "No dictionary entry for " + popup.number + "."
        textFormat: Text.PlainText
        color: popup.foreground
        opacity: popup.opacitySecondary
        font.family: popup.fontFamily
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.WordWrap
      }
    }

    // Bare-card click layer (z below the content Column): a click that
    // reaches the card's own background — not the close button, not a text
    // run — also closes.
    MouseArea {
      z: -1
      anchors.fill: parent
      onClicked: popup.close()
    }
  }

  // No fullscreen scrim/click-grab overlay: nothing else in this codebase
  // installs one inside the panel's key catcher, and an input-grabbing
  // overlay across a layer-shell surface is the least-proven construct
  // here. The card closes via Esc (panel key catcher), the ✕ button, and
  // the panel lifecycle hooks below instead.

  // A stale open card must not survive a tab switch or a panel close
  // (mirrors InPanelDropdown's lifecycle rules).
  Connections {
    target: popup.panel
    function onCurrentTabChanged() { if (popup.popupOpen) popup.close() }
    function onOpenedChanged() { if (!panel.opened && popup.popupOpen) popup.close() }
    function onExpandedChanged() { if (popup.popupOpen) popup.close() }
  }
}