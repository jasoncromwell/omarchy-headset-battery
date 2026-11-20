import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pipewire
import Quickshell.Services.UPower
import qs.Ui
import qs.Commons
import qs.Commons as Commons

// Headset Battery - an Omarchy bar widget.
// https://github.com/jasoncromwell/omarchy-headset-battery  (MIT)
//
// Shows the battery of a wireless headset (anything UPower reports as a
// headset or headphones: USB dongle or Bluetooth). Hidden when none is present.
//   Left click   - headset details panel
//   Middle click - Omarchy's audio panel
// Settings (shell.json / widget settings):
//   lowThreshold            percent at or below which the widget turns the
//                           urgent color while on battery (default 15)
//   holdLevelWhileCharging  show the last on-battery reading while plugged in
//                           instead of the headset's own report (default true)
Panel {
  id: root
  moduleName: "io.github.jasoncromwell.headset-battery"
  ipcTarget: "io.github.jasoncromwell.headset-battery"

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  // ---------------------------------------------------------------- UPower
  readonly property var device: {
    var devs = UPower.devices ? UPower.devices.values : []
    for (var i = 0; i < devs.length; i++) {
      var d = devs[i]
      if (d && d.isPresent && (d.type === UPowerDeviceType.Headset || d.type === UPowerDeviceType.Headphones))
        return d
    }
    return null
  }
  readonly property bool present: device !== null
  readonly property real liveFraction: device ? Math.max(0, Math.min(1, device.percentage)) : 0

  // Plugged in or not. Charging, FullyCharged and PendingCharge mean plugged
  // in; Discharging, PendingDischarge and Empty mean on battery. Many
  // Bluetooth headsets only ever report Unknown, and the Corsair Void reports
  // Unknown in passing while charging, so Unknown keeps the last known answer
  // (on battery until anything says otherwise).
  property bool plugged: false
  readonly property int deviceState: device ? device.state : -1
  function updatePlugged() {
    if (!device) { plugged = false; return }
    var st = device.state
    if (st === UPowerDeviceState.Charging || st === UPowerDeviceState.FullyCharged || st === UPowerDeviceState.PendingCharge)
      plugged = true
    else if (st === UPowerDeviceState.Discharging || st === UPowerDeviceState.PendingDischarge || st === UPowerDeviceState.Empty)
      plugged = false
  }
  onDeviceStateChanged: updatePlugged()
  readonly property bool charging: present && plugged
  readonly property bool onBattery: present && !plugged

  // Headsets like the Corsair Void report a meaningless level while plugged
  // in: it climbs from 21% to "fully charged" within half a minute as the
  // charger raises the voltage, then drops back to the real level the moment
  // it is unplugged. With holdLevelWhileCharging on (the default), only
  // readings taken on battery are trusted, and while plugged in the widget
  // shows the last on-battery reading instead, a floor for the real level.
  // It is saved to a state file so a shell restart while charging keeps it.
  readonly property bool holdLevel: setting("holdLevelWhileCharging", true) !== false
  readonly property bool holding: charging && holdLevel
  property real savedFraction: -1
  property string savedModel: ""
  readonly property bool savedValid: savedFraction >= 0 && savedModel === model
  readonly property real fraction: !holding ? liveFraction : (savedValid ? savedFraction : 0)
  readonly property int percent: !present ? -1 : (!holding ? Math.round(liveFraction * 100) : (savedValid ? Math.round(savedFraction * 100) : -1))
  readonly property bool low: onBattery && percent >= 0 && percent <= Number(setting("lowThreshold", 15))

  function recordReading() {
    if (!onBattery || model === "") return
    var rounded = Math.round(liveFraction * 100) / 100
    if (rounded === savedFraction && savedModel === model) return
    savedFraction = rounded
    savedModel = model
    stateFile.setText(JSON.stringify({ model: model, fraction: rounded, time: Date.now() }) + "\n")
  }
  onLiveFractionChanged: recordReading()
  onOnBatteryChanged: recordReading()
  onHoldingChanged: seedFromHistory()

  FileView {
    id: stateFile
    path: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/io.github.jasoncromwell.headset-battery.json"
    printErrors: false
    watchChanges: false
    onLoaded: {
      try {
        var s = JSON.parse(text())
        var f = Number(s.fraction)
        if (isFinite(f) && f >= 0 && f <= 1 && typeof s.model === "string") {
          root.savedFraction = f
          root.savedModel = s.model.slice(0, 200)
        }
      } catch (e) {}
      root.recordReading()
      root.seedFromHistory()
    }
    onLoadFailed: { root.recordReading(); root.seedFromHistory() }
  }

  // No saved reading yet (first run, or plugged in before the widget ever saw
  // the headset on battery): fall back to the newest "discharging" sample in
  // UPower's own charge history. The live history (upower --dump) keeps only
  // the last few samples, which charging soon pushes out, so UPower's history
  // file on disk (written every few minutes) is the second source.
  function seedFromHistory() {
    if (!holding || savedValid || historyProc.running || model === "") return
    // Built here rather than bound: a binding on model can still hold the old
    // value when onModelChanged runs. The path is an argument, never spliced
    // into the script.
    historyProc.command = ["sh", "-c", "upower --dump; echo '@@HISTORY-FILE@@'; tac -- \"$1\" 2>/dev/null | head -n 5000",
      "sh", "/var/lib/upower/history-charge-" + model.replace(/[^A-Za-z0-9._-]/g, "_") + ".dat"]
    historyProc.running = true
  }

  function newestDischarging(lines) {
    for (var i = 0; i < lines.length && i < 5000; i++) {
      var parts = String(lines[i]).trim().split(/\s+/)
      if (parts.length !== 3 || parts[2] !== "discharging") continue
      var pct = Number(parts[1])
      if (isFinite(pct) && pct >= 0 && pct <= 100) return pct / 100
    }
    return -1
  }

  Process {
    id: historyProc
    stdout: StdioCollector {
      onStreamFinished: {
        if (root.savedValid || !root.device) return
        var halves = String(text || "").split("@@HISTORY-FILE@@")
        var native = String(root.device.nativePath || "")
        var found = -1
        var blocks = halves[0].split(/\n(?=Device: )/)
        for (var b = 0; b < blocks.length && native !== ""; b++) {
          var m = blocks[b].match(/native-path:\s*(\S+)/)
          if (!m || m[1] !== native) continue
          found = root.newestDischarging((blocks[b].split("History (charge):")[1] || "").split("\n"))
          break
        }
        if (found < 0 && halves.length > 1) found = root.newestDischarging(halves[1].split("\n"))
        if (found >= 0) {
          root.savedFraction = Math.round(found * 100) / 100
          root.savedModel = root.model
        }
      }
    }
  }
  readonly property string model: device ? String(device.model || "") : ""
  // "CORSAIR VOID ELITE Wireless Gaming Dongle" -> "CORSAIR VOID ELITE"
  readonly property string displayName: {
    var n = model.replace(/\s+(wireless\s+)?(gaming\s+)?(dongle|receiver|adapter)$/i, "").trim()
    return n || "Headset"
  }
  readonly property string sysfsDir: device && device.nativePath
    ? "/sys/class/power_supply/" + String(device.nativePath) + "/device"
    : ""

  function stateText() {
    if (!device) return ""
    return onBattery ? strings.t("state.discharging") : strings.t("state.charging")
  }

  function duration(seconds) {
    var s = Number(seconds || 0)
    if (!(s > 0)) return ""
    var h = Math.floor(s / 3600)
    var m = Math.round((s % 3600) / 60)
    return h > 0 ? strings.t("duration.hm").arg(h).arg(m) : strings.t("duration.m").arg(Math.max(1, m))
  }

  // Shown only when the device reports one. Time to full is derived from the
  // charging level, so it is hidden while that level is being held.
  readonly property string timeText: onBattery ? duration(device.timeToEmpty)
    : (charging && !holdLevel ? duration(device.timeToFull) : "")

  // -------------------------------------------------------------- PipeWire
  // The headset's own sink/source: PipeWire names them after the same USB
  // product string UPower reports as the model.
  readonly property var nodes: Pipewire.nodes ? Pipewire.nodes.values : []
  function matchesHeadset(n) {
    if (!n || n.isStream || model === "") return false
    var desc = String(n.description || n.nickname || "")
    var name = String(n.name || "")
    return desc.indexOf(model) === 0 || name.indexOf(model.replace(/\s+/g, "_")) !== -1
  }
  readonly property var sinkNode: {
    for (var i = 0; i < nodes.length; i++)
      if (nodes[i] && nodes[i].isSink && matchesHeadset(nodes[i])) return nodes[i]
    return null
  }
  readonly property var sourceNode: {
    for (var i = 0; i < nodes.length; i++)
      if (nodes[i] && !nodes[i].isSink && matchesHeadset(nodes[i])) return nodes[i]
    return null
  }
  readonly property bool isDefaultOutput: !!sinkNode && Pipewire.defaultAudioSink === sinkNode

  PwObjectTracker { objects: [root.sinkNode, root.sourceNode].filter(function(n) { return !!n }) }

  function volumeText(node) {
    if (!node || !node.audio) return "—"
    if (node.audio.muted) return strings.t("audio.muted")
    return Commons.I18n.formatNumber(Math.round(node.audio.volume * 100)) + "%"
  }

  function makeDefaultOutput() {
    var node = sinkNode
    if (!node) return
    Pipewire.preferredDefaultAudioSink = node
    if (node.id !== undefined && node.name)
      Quickshell.execDetached(["omarchy-audio-output-set-default", String(node.id), String(node.name)])
  }

  function openMixer() {
    close()
    if (bar) bar.run("omarchy-shell shell toggle omarchy.audio")
  }

  // ------------------------------------------------- driver sysfs details
  // hid-corsair-void (and similar drivers) expose extra read-only attributes
  // next to the battery. Missing files are simply skipped. sysfs does not
  // support change notification, so these refresh while the panel is open.
  property var hw: ({})

  Process {
    id: hwProc
    command: root.sysfsDir === "" ? ["true"] : ["grep", "-sH", "",
      root.sysfsDir + "/microphone_up",
      root.sysfsDir + "/fw_version_headset",
      root.sysfsDir + "/fw_version_receiver"]
    stdout: StdioCollector {
      onStreamFinished: {
        var out = {}
        var lines = String(text || "").split("\n")
        for (var i = 0; i < lines.length && i < 16; i++) {
          var line = lines[i]
          var colon = line.lastIndexOf(":")
          if (colon < 0) continue
          var key = line.slice(0, colon).split("/").pop()
          out[key] = line.slice(colon + 1).trim().slice(0, 32)
        }
        root.hw = out
      }
    }
  }

  Timer {
    interval: 3000
    repeat: true
    triggeredOnStart: true
    running: root.opened && root.sysfsDir !== ""
    onTriggered: if (!hwProc.running) hwProc.running = true
  }

  readonly property string boomText: hw.microphone_up === "1" ? strings.t("mic.boomUp")
    : (hw.microphone_up === "0" ? strings.t("mic.boomDown") : "")

  // ------------------------------------------------------------------- UI
  visible: present
  implicitWidth: present ? button.implicitWidth : 0
  implicitHeight: present ? button.implicitHeight : 0
  onPresentChanged: { if (!present) close(); else seedFromHistory() }
  onModelChanged: seedFromHistory()

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.charging ? "󱐋" : "󰋋"
    labelText: root.percent >= 0 && !vertical ? Commons.I18n.formatNumber(root.percent) + "%" : ""
    slotSize: Style.bar.iconSlot * (root.percent >= 0 && !vertical ? 2 : 1)
    active: root.low
    tooltipText: root.opened || !root.device ? ""
      : (!root.holding
        ? strings.t("tooltip").arg(root.displayName).arg(Commons.I18n.formatNumber(root.percent)).arg(root.stateText())
        : (root.percent >= 0
          ? strings.t("tooltip.charging").arg(root.displayName).arg(Commons.I18n.formatNumber(root.percent))
          : strings.t("tooltip.chargingUnknown").arg(root.displayName)))
    onPressed: function(b) {
      if (b === Qt.MiddleButton) root.openMixer()
      else if (b === Qt.LeftButton) root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened && root.present
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight)

    content: PanelKeyCatcher {
      anchors.fill: parent
      implicitHeight: column.implicitHeight
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(14)

        // ---------- Hero: headset icon · name/status · percentage ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, heroPercent.implicitHeight)

          Text {
            id: heroIcon
            textFormat: Text.PlainText
            text: "󰋋"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.display
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: heroPercent.left
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              text: root.displayName
              textFormat: Text.PlainText
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              textFormat: Text.PlainText
              text: ((root.low ? strings.t("battery.low") + " · " : "") + root.stateText()).toUpperCase()
              color: root.low ? root.bar.urgent : Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              elide: Text.ElideRight
              width: parent.width
            }
          }

          Text {
            id: heroPercent
            textFormat: Text.PlainText
            text: root.percent >= 0 ? Commons.I18n.formatNumber(root.percent) + "%" : "—"
            color: root.low ? root.bar.urgent : root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.displayLarge
            font.bold: true
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        // ---------- Charge bar ----------
        Item {
          width: parent.width
          implicitHeight: Style.space(8)

          Rectangle {
            id: track
            anchors.fill: parent
            radius: height / 2
            color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.12)
          }

          Rectangle {
            anchors.left: track.left
            anchors.verticalCenter: track.verticalCenter
            height: track.height
            radius: track.radius
            color: root.low ? root.bar.urgent : root.bar.foreground
            width: Math.max(track.height, track.width * root.fraction)
            Behavior on width { NumberAnimation { duration: Style.duration(240); easing.type: Easing.OutCubic } }
          }
        }

        InfoPair {
          visible: root.timeText !== ""
          label: root.charging ? strings.t("battery.timeToFull") : strings.t("battery.timeLeft")
          value: root.timeText
        }

        Text {
          visible: root.holding
          width: parent.width
          wrapMode: Text.WordWrap
          textFormat: Text.PlainText
          text: root.percent >= 0 ? strings.t("battery.chargingNote").arg(Commons.I18n.formatNumber(root.percent))
                                  : strings.t("battery.chargingNoteUnknown")
          color: root.bar.foreground
          opacity: 0.6
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        // ---------- Audio ----------
        PanelSeparator { foreground: root.bar.foreground }

        Column {
          width: parent.width
          spacing: Style.spacing.labelGap

          PanelSectionHeader {
            text: strings.t("section.audio")
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          InfoPair {
            visible: root.sinkNode !== null
            label: strings.t("audio.default")
            value: root.isDefaultOutput ? strings.t("audio.yes") : strings.t("audio.no")
          }
          InfoPair {
            visible: root.sinkNode !== null
            label: strings.t("audio.output")
            value: root.volumeText(root.sinkNode)
          }
          InfoPair {
            visible: root.sourceNode !== null
            label: strings.t("audio.mic")
            value: root.volumeText(root.sourceNode)
          }
          InfoPair {
            visible: root.boomText !== ""
            label: strings.t("mic.boom")
            value: root.boomText
          }
        }

        Row {
          width: parent.width
          spacing: Style.space(6)
          readonly property int buttons: makeDefault.visible ? 2 : 1
          readonly property real cellWidth: (width - spacing * (buttons - 1)) / buttons

          Button {
            id: makeDefault
            visible: root.sinkNode !== null && !root.isDefaultOutput
            width: parent.cellWidth
            iconText: "󰓃"
            text: strings.t("audio.makeDefault")
            fontSize: Style.font.bodySmall
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            bordered: true
            onClicked: root.makeDefaultOutput()
          }
          Button {
            width: parent.cellWidth
            iconText: "󰕾"
            text: strings.t("audio.openMixer")
            fontSize: Style.font.bodySmall
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            bordered: true
            onClicked: root.openMixer()
          }
        }

        // ---------- Device ----------
        PanelSeparator {
          visible: deviceColumn.visible
          foreground: root.bar.foreground
        }

        Column {
          id: deviceColumn
          visible: !!(root.hw.fw_version_headset || root.hw.fw_version_receiver)
          width: parent.width
          spacing: Style.spacing.labelGap

          PanelSectionHeader {
            text: strings.t("section.device")
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }
          InfoPair {
            visible: !!root.hw.fw_version_headset
            label: strings.t("device.fwHeadset")
            value: root.hw.fw_version_headset || ""
          }
          InfoPair {
            visible: !!root.hw.fw_version_receiver
            label: strings.t("device.fwReceiver")
            value: root.hw.fw_version_receiver || ""
          }
        }
      }
    }
  }

  component InfoPair: Row {
    property string label: ""
    property string value: ""

    width: parent.width
    spacing: Style.space(8)

    InfoLabel { text: label }
    Item { width: Math.max(0, parent.width - parent.children[0].implicitWidth - parent.children[2].implicitWidth - parent.spacing * 2); height: 1 }
    InfoValue { text: value }
  }

  component InfoLabel: Text {
    textFormat: Text.PlainText
    color: root.bar.foreground
    opacity: 0.6
    font.family: root.bar.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  component InfoValue: Text {
    textFormat: Text.PlainText
    color: root.bar.foreground
    font.family: root.bar.fontFamily
    font.pixelSize: Style.font.bodySmall
  }
}
