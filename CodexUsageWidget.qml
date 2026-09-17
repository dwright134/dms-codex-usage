import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins
import "translations.js" as Tr

PluginComponent {
    id: root

    IpcHandler {
        enabled: root.axis !== null
        target: root.isVertical ? "codex-layout-side" : "codex-layout-wide"
        function open(): string { root.triggerPopout(); return "opened"; }
        function toggle(): string { root.savePreference("detailsExpanded", !root.detailsExpanded); return "toggled"; }
    }
    // i18n
    property string lang: Qt.locale().name.split(/[_-]/)[0]
    function tr(key) {
        return Tr.tr(key, lang);
    }

    // Settings
    property int refreshInterval: [15, 30, 60, 300].indexOf(Number(pluginData.refreshSeconds)) !== -1 ? Number(pluginData.refreshSeconds) * 1000 : 30000
    property bool showIcon: pluginData.showIcon !== false       // default on
    property bool showPacing: pluginData.showPacing !== false
    property real subscriptionCost: Math.max(0, parseFloat(pluginData.subscriptionCost || "20") || 0)

    // Account/session state
    property bool loggedIn: false
    property bool isLoading: true
    property string account: ""
    property string plan: ""
    property string cliVersion: ""
    property string pluginVersion: ""
    property bool liveData: false
    property string updatedAt: ""
    property var stats: ({})
    property real maxDaily: Math.max.apply(null, [1].concat(chartData.map(function(d) { return d.tokens; })))
    property bool detailsExpanded: pluginData.detailsExpanded !== false
    property bool alertsEnabled: pluginData.alertsEnabled === true
    property int chartDays: Number(pluginData.chartDays) === 30 ? 30 : 7
    property var chartData: chartDays === 30 ? (stats.daily30 || []) : (stats.daily || [])
    property string hoveredDay: ""
    onChartDaysChanged: hoveredDay = ""
    property real snapshotAge: updatedAt ? Math.max(0, countdownNow - new Date(updatedAt).getTime()) : Infinity
    property bool snapshotStale: !isFinite(snapshotAge) || snapshotAge > 30 * 60000
    property string freshnessText: {
        if (!updatedAt) return "Waiting for a local snapshot";
        if (!isFinite(snapshotAge)) return "Snapshot time unavailable";
        var minutes = Math.floor(snapshotAge / 60000);
        var age = minutes < 1 ? "just now" : (minutes < 60 ? minutes + " min ago" : (minutes < 1440 ? Math.floor(minutes / 60) + "h ago" : Math.floor(minutes / 1440) + "d ago"));
        return (snapshotStale ? "Stale · " : "Updated ") + age;
    }
    property string weekTrend: {
        var previous = stats.previous_week || 0;
        if (!previous) return "Daily tokens · last 7 days";
        var change = Math.round(((stats.week || 0) - previous) / previous * 100);
        return (change > 0 ? "+" : "") + change + "% vs previous 7 days";
    }
    property string breakdownText: {
        var b = stats.breakdown_week || {};
        if (b.input_tokens === undefined && b.output_tokens === undefined) return "Token breakdown unavailable in local logs";
        return "7d input " + compact(b.input_tokens || 0) + " · output " + compact(b.output_tokens || 0)
            + "\nCached input " + compact(b.cached_input_tokens || 0) + " (included in input)";
    }
    function savePreference(key, value) {
        SettingsData.setPluginSetting("codexUsage", key, value);
        pluginData = SettingsData.getPluginSettingsForPlugin("codexUsage");
    }
    function checkAlerts() {
        if (!alertsEnabled || snapshotStale || !loggedIn) return;
        var seen = Object.assign({}, pluginData.alertHistory || {});
        var changed = false;
        ["primary", "secondary"].forEach(function(id) {
            var b = buckets[id];
            if (!b || b.REMAINING === undefined || !b.RESET || new Date(b.RESET).getTime() <= Date.now()) return;
            var used = Math.max(0, Math.min(100, (1 - Number(b.REMAINING)) * 100));
            var level = used >= 90 ? 90 : (used >= 80 ? 80 : 0);
            var prior = seen[id] || {};
            if (!level || (prior.reset === b.RESET && prior.level >= level)) return;
            ToastService.showWarning("Codex " + (b.LABEL || (id === "primary" ? "5h budget" : "weekly limit")) + ": " + Math.round(used) + "%", "Resets in " + countdown(b.RESET));
            seen[id] = {reset: b.RESET, level: level};
            changed = true;
        });
        if (changed) savePreference("alertHistory", seen);
    }
    function compact(value) {
        if (value >= 1000000000) return (value / 1000000000).toFixed(1) + "B";
        if (value >= 1000000) return (value / 1000000).toFixed(1) + "M";
        if (value >= 1000) return (value / 1000).toFixed(1) + "K";
        return String(Math.round(value));
    }
    function money(value) {
        value = Number(value || 0);
        if (value >= 1000) return "$" + (value / 1000).toFixed(1) + "K";
        if (value >= 100) return "$" + Math.round(value);
        if (value >= 10) return "$" + value.toFixed(1);
        return "$" + value.toFixed(2);
    }
    function valueText() {
        var estimate = Number(stats.month_cost || 0);
        var difference = estimate - subscriptionCost;
        return "API equivalent this month " + money(estimate)
            + " · subscription " + money(subscriptionCost)
            + (difference >= 0 ? " · " + money(difference) + " above plan cost" : "");
    }

    // Quota buckets: id -> { GROUP, GROUP_DESC, LABEL, WINDOW, REMAINING, RESET, DESC }
    property var buckets: ({})
    property var bucketOrder: []

    // Live countdown clock
    property real countdownNow: Date.now()

    // --- Derived ---

    // Grouped view: [{ name, desc, buckets:[{id,label,window,remaining,reset,desc}] }]
    property var groups: {
        void (buckets);
        void (bucketOrder);
        var seen = {};
        var out = [];
        for (var i = 0; i < bucketOrder.length; i++) {
            var id = bucketOrder[i];
            var b = buckets[id];
            if (!b)
                continue;
            var gname = b.GROUP || "";
            if (!(gname in seen)) {
                seen[gname] = {
                    "name": gname,
                    "desc": b.GROUP_DESC || "",
                    "buckets": []
                };
                out.push(seen[gname]);
            }
            seen[gname].buckets.push({
                "id": id,
                "label": b.LABEL || "",
                "window": b.WINDOW || "",
                "remaining": (b.REMAINING !== undefined ? parseFloat(b.REMAINING) : 1),
                "reset": b.RESET || "",
                "desc": b.DESC || ""
            });
        }
        return out;
    }

    // Tightest (most-consumed) limit across all buckets, as a 0..100 "used" percentage.
    property real tightestUsed: {
        void (buckets);
        void (bucketOrder);
        var maxUsed = 0;
        for (var i = 0; i < bucketOrder.length; i++) {
            var b = buckets[bucketOrder[i]];
            if (!b || b.REMAINING === undefined)
                continue;
            var u = (1 - parseFloat(b.REMAINING)) * 100;
            if (u > maxUsed)
                maxUsed = u;
        }
        return maxUsed;
    }

    popoutWidth: isVertical ? 420 : 680
    popoutHeight: isVertical ? (detailsExpanded ? 900 : 590) : (detailsExpanded ? 730 : 510)

    // --- Helpers ---

    function progressColor(usedPct) {
        if (usedPct > 80)
            return Theme.error;
        if (usedPct > 50)
            return Theme.warning;
        return Theme.primary;
    }

    // ISO timestamp -> "2d 3h 04m" / "3h 04m" countdown relative to countdownNow.
    function countdown(resetIso) {
        if (!resetIso)
            return "";
        var resetMs = new Date(resetIso).getTime();
        if (isNaN(resetMs))
            return "";
        var remaining = Math.max(0, resetMs - countdownNow);
        if (remaining <= 0)
            return tr("Resetting...");
        var days = Math.floor(remaining / 86400000);
        var hours = Math.floor((remaining % 86400000) / 3600000);
        var mins = Math.floor((remaining % 3600000) / 60000);
        if (days > 0)
            return days + "d " + hours + "h " + (mins < 10 ? "0" : "") + mins + "m";
        return hours + "h " + (mins < 10 ? "0" : "") + mins + "m";
    }

    function setBucketField(id, field, val) {
        var b = Object.assign({}, buckets);
        var cur = b[id] ? Object.assign({}, b[id]) : {};
        cur[field] = val;
        b[id] = cur;
        buckets = b;
    }

    // Field suffixes in priority order (longest/ambiguous first).
    property var _bucketFields: ["GROUP_DESC", "PACE_DELTA", "ESTIMATED", "GROUP", "LABEL", "WINDOW", "REMAINING", "RESET", "PACE", "DESC"]

    function parseLine(line) {
        var idx = line.indexOf("=");
        if (idx < 0)
            return;
        var key = line.substring(0, idx);
        var val = line.substring(idx + 1);

        if (key.indexOf("BUCKET_") === 0) {
            var rest = key.substring(7);
            for (var i = 0; i < _bucketFields.length; i++) {
                var suf = "_" + _bucketFields[i];
                if (rest.length > suf.length && rest.substring(rest.length - suf.length) === suf) {
                    var id = rest.substring(0, rest.length - suf.length);
                    setBucketField(id, _bucketFields[i], val);
                    return;
                }
            }
            return;
        }

        switch (key) {
        case "STATS":
            try { stats = JSON.parse(val); } catch (e) { stats = ({}); }
            break;
        case "LOGGED_IN":
            loggedIn = (val === "true");
            break;
        case "ACCOUNT":
            account = val;
            break;
        case "PLAN":
            plan = val;
            break;
        case "UPDATED_AT":
            updatedAt = val;
            break;
        case "CLI_VERSION":
            cliVersion = val;
            break;
        case "LIVE":
            liveData = (val === "true");
            break;
        case "VERSION":
            pluginVersion = val;
            break;
        case "GROUPS":
            // New refresh: reset the bucket store, set the canonical order.
            buckets = ({});
            bucketOrder = val.length > 0 ? val.split(",") : [];
            break;
        }
    }

    // --- Data fetching ---

    property string scriptPath: PluginService.pluginDirectory + "/codexUsage/get-codex-usage.py"
    property string logoSource: "file://" + PluginService.pluginDirectory + "/codexUsage/icon.svg"

    Process {
        id: usageProcess
        command: ["python3", root.scriptPath]
        running: false

        stdout: SplitParser {
            onRead: data => root.parseLine(data.trim())
        }

        onExited: (exitCode, exitStatus) => {
            root.isLoading = false;
            if (exitCode === 0) root.checkAlerts();
        }
    }

    Timer {
        interval: root.refreshInterval
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            if (!usageProcess.running)
                usageProcess.running = true;
        }
    }

    // Live countdown + wake-from-sleep detection
    Timer {
        interval: 60000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            var now = Date.now();
            var elapsed = now - root.countdownNow;
            root.countdownNow = now;
            if (elapsed > 120000 && !usageProcess.running)
                usageProcess.running = true;
        }
    }

    // --- Taskbar pills (ring shows tightest used limit) ---

    function limitText(id) {
        var b = buckets[id];
        return b && b.REMAINING !== undefined
            ? Math.round((1 - parseFloat(b.REMAINING)) * 100) + "%" : "—";
    }

    horizontalBarPill: Component {
        Row {
            spacing: Theme.spacingS
            DankIcon {
                name: "terminal"
                size: 18
                color: Theme.primary
                visible: root.showIcon
                anchors.verticalCenter: parent.verticalCenter
            }
            StyledText {
                text: "5h " + root.limitText("primary")
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceText
            }
            StyledText {
                text: "Week " + root.limitText("secondary")
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceText
            }
        }
    }

    verticalBarPill: Component {
        Column {
            spacing: Theme.spacingXS || 4

            DankIcon {
                name: "terminal"
                size: 18
                color: Theme.primary
                anchors.horizontalCenter: parent.horizontalCenter
                visible: root.showIcon
            }

            Repeater {
                model: ["primary", "secondary"]
                delegate: Column {
                    required property string modelData
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: 2

                    Canvas {
                        width: 20
                        height: 20
                        anchors.horizontalCenter: parent.horizontalCenter
                        renderStrategy: Canvas.Cooperative
                        property real percent: {
                            var b = root.buckets[modelData];
                            return b && b.REMAINING !== undefined
                                ? Math.max(0, Math.min(100, (1 - parseFloat(b.REMAINING)) * 100)) : 0;
                        }
                        property color ringColor: root.progressColor(percent)
                        property color trackColor: Theme.surfaceVariant
                        onPercentChanged: requestPaint()
                        onRingColorChanged: requestPaint()
                        onTrackColorChanged: requestPaint()
                        onPaint: {
                            var ctx = getContext("2d");
                            ctx.reset();
                            var cx = width / 2, cy = height / 2, r = 7.5;
                            ctx.beginPath();
                            ctx.arc(cx, cy, r, 0, 2 * Math.PI);
                            ctx.lineWidth = 2.5;
                            ctx.strokeStyle = trackColor;
                            ctx.stroke();
                            if (percent > 0) {
                                ctx.beginPath();
                                ctx.arc(cx, cy, r, -Math.PI / 2, -Math.PI / 2 + 2 * Math.PI * percent / 100);
                                ctx.strokeStyle = ringColor;
                                ctx.lineCap = "round";
                                ctx.stroke();
                            }
                        }
                    }

                    StyledText {
                        text: root.limitText(modelData)
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceText
                        anchors.horizontalCenter: parent.horizontalCenter
                    }
                }
            }
        }
    }

    component UsageRing: Item {
        property real percent: 0
        property real pacePercent: 0
        property bool showPace: false
        property color accent: Theme.primary
        width: 76
        height: 76
        Canvas {
            anchors.fill: parent
            property real value: parent.percent
            Behavior on value { NumberAnimation { duration: 350; easing.type: Easing.OutCubic } }
            property color ink: parent.accent
            property color track: Theme.surfaceVariant
            onValueChanged: requestPaint()
            property real paceValue: parent.pacePercent
            onPaceValueChanged: requestPaint()
            property bool paceVisible: parent.showPace
            onPaceVisibleChanged: requestPaint()
            onInkChanged: requestPaint()
            onTrackChanged: requestPaint()
            onPaint: {
                var ctx = getContext("2d");
                ctx.reset();
                ctx.lineWidth = 5;
                ctx.lineCap = "round";
                ctx.beginPath(); ctx.arc(width/2, height/2, width/2-5, 0, Math.PI*2);
                ctx.strokeStyle = track; ctx.stroke();
                if (value > 0) {
                    ctx.beginPath();
                    ctx.arc(width/2, height/2, width/2-5, -Math.PI/2, -Math.PI/2+Math.PI*2*Math.min(100,value)/100);
                    ctx.strokeStyle = ink; ctx.stroke();
                }
                if (paceVisible) {
                    var angle = -Math.PI/2 + Math.PI*2*Math.max(0, Math.min(100, paceValue))/100;
                    var radius = width/2-5;
                    ctx.beginPath();
                    ctx.moveTo(width/2 + (radius-4)*Math.cos(angle), height/2 + (radius-4)*Math.sin(angle));
                    ctx.lineTo(width/2 + (radius+4)*Math.cos(angle), height/2 + (radius+4)*Math.sin(angle));
                    ctx.lineWidth = 2; ctx.lineCap = "butt"; ctx.strokeStyle = Theme.surfaceText; ctx.stroke();
                }
            }
        }
        Column {
            anchors.centerIn: parent
            spacing: 1
            StyledText {
                anchors.horizontalCenter: parent.horizontalCenter
                text: Math.round(parent.parent.percent) + "%"
                color: Theme.surfaceText
                font.pixelSize: 22
                font.weight: Font.Bold
            }
            StyledText {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "used"
                color: Theme.surfaceVariantText
                font.pixelSize: 10
            }
        }
    }

    component BackgroundGlow: Canvas {
        property color glowColor: Theme.primary
        width: 130
        height: width
        opacity: 0.22
        onGlowColorChanged: requestPaint()
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
        onPaint: {
            var ctx = getContext("2d");
            ctx.reset();
            var radius = width / 2;
            var glow = ctx.createRadialGradient(radius, height / 2, 0, radius, height / 2, radius);
            glow.addColorStop(0, glowColor.toString());
            glow.addColorStop(1, "transparent");
            ctx.fillStyle = glow;
            ctx.fillRect(0, 0, width, height);
        }
    }

    component DashboardCard: Rectangle {
        id: cardSurface
        property color tint: Theme.primary
        radius: 18
        border.width: 1
        border.color: Theme.withAlpha(tint, 0.16)
        gradient: Gradient {
            GradientStop { position: 0; color: Qt.tint(Theme.surfaceContainer, Theme.withAlpha(tint, 0.09)) }
            GradientStop { position: 1; color: Qt.tint(Theme.surfaceContainer, Theme.withAlpha(tint, 0.025)) }
        }
        Canvas {
            anchors.fill: parent
            property color glowColor: cardSurface.tint
            opacity: 0.20
            onGlowColorChanged: requestPaint()
            onWidthChanged: requestPaint()
            onHeightChanged: requestPaint()
            onPaint: {
                var ctx = getContext("2d");
                ctx.reset();
                var r = Math.min(cardSurface.radius, width / 2, height / 2);
                ctx.beginPath();
                ctx.moveTo(r, 0);
                ctx.lineTo(width - r, 0);
                ctx.quadraticCurveTo(width, 0, width, r);
                ctx.lineTo(width, height - r);
                ctx.quadraticCurveTo(width, height, width - r, height);
                ctx.lineTo(r, height);
                ctx.quadraticCurveTo(0, height, 0, height - r);
                ctx.lineTo(0, r);
                ctx.quadraticCurveTo(0, 0, r, 0);
                ctx.closePath();
                ctx.clip();
                var reach = Math.min(width * 0.65, 150);
                var glow = ctx.createRadialGradient(width, height * 0.45, 0, width, height * 0.45, reach);
                glow.addColorStop(0, glowColor.toString());
                glow.addColorStop(1, "transparent");
                ctx.fillStyle = glow;
                ctx.fillRect(0, 0, width, height);
            }
        }
    }

    component ActionChip: Rectangle {
        id: chip
        property string label: ""
        property bool selected: false
        signal clicked()
        width: chipText.implicitWidth + 22
        height: 30
        radius: 15
        border.width: 1
        border.color: Theme.withAlpha(Theme.primary, selected ? 0.24 : 0.09)
        Behavior on color { ColorAnimation { duration: 140 } }
        color: selected ? Theme.withAlpha(Theme.primary, 0.16) : (chipMouse.containsMouse ? Theme.surfaceContainerHigh : "transparent")
        StyledText {
            id: chipText
            anchors.centerIn: parent
            text: chip.label
            font.pixelSize: 12
            font.weight: chip.selected ? Font.DemiBold : Font.Normal
            color: chip.selected ? Theme.primary : Theme.surfaceVariantText
        }
        MouseArea {
            id: chipMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: chip.clicked()
        }
    }

    popoutContent: Component {
        PopoutComponent {
            id: dashboard

            // Blend with the active surface so light and dark themes stay readable.
            Rectangle {
                parent: dashboard.parent
                anchors.fill: parent
                anchors.margins: -Theme.spacingS
                z: -1
                radius: 16
                border.width: 1
                border.color: Theme.withAlpha(Theme.primary, 0.22)
                gradient: Gradient {
                    GradientStop { position: 0.0; color: Qt.tint(Theme.surfaceContainerLow, Theme.withAlpha(Theme.primary, 0.22)) }
                    GradientStop { position: 0.48; color: Qt.tint(Theme.surfaceContainerLow, Theme.withAlpha(Theme.secondary, 0.12)) }
                    GradientStop { position: 1.0; color: Theme.surfaceContainerLow }
                }

                BackgroundGlow {
                    x: parent.width * 0.08
                    y: 8
                    glowColor: Theme.primary
                }
                BackgroundGlow {
                    anchors.right: parent.right
                    anchors.rightMargin: 8
                    y: parent.height * 0.34
                    width: 110
                    glowColor: Theme.secondary
                }
                BackgroundGlow {
                    x: parent.width * 0.25
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: 8
                    width: 100
                    glowColor: Theme.tertiary
                    opacity: 0.18
                }
            }

            function centerTopPopout() {
                if (!root.axis || root.axis.edge !== "top" || !parentPopout || !parentPopout.screen) return;
                const centeredTrigger = (parentPopout.screen.width - parentPopout.triggerWidth) / 2;
                if (parentPopout.triggerX !== centeredTrigger)
                    parentPopout.triggerX = centeredTrigger;
            }

            onParentPopoutChanged: {
                if (!parentPopout) return;
                // Keep the surface stable while using the shell's default popup animation.
                parentPopout.fullHeightSurface = true;
                centerTopPopout();
            }
            Connections {
                target: dashboard.parentPopout
                function onTriggerXChanged() { dashboard.centerTopPopout(); }
                function onTriggerWidthChanged() { dashboard.centerTopPopout(); }
                function onScreenChanged() { dashboard.centerTopPopout(); }
                function onShouldBeVisibleChanged() { dashboard.centerTopPopout(); }
            }
            headerText: ""
            detailsText: ""
            showCloseButton: false
            Flickable {
                width: parent.width
                height: Math.min(contentHeight, Math.max(240, ((dashboard.parentPopout && dashboard.parentPopout.screen) ? dashboard.parentPopout.screen.height : 1000) - 160))
                contentHeight: dashboardBody.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                flickableDirection: Flickable.VerticalFlick
                Column {
                    id: dashboardBody
                    width: parent.width - 16
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: 12

                    Row {
                        width: parent.width
                        spacing: 8
                        DankIcon { name: "terminal"; size: 24; color: Theme.primary; anchors.verticalCenter: parent.verticalCenter }
                        StyledText { id: dashboardTitle; text: "Codex Usage"; font.pixelSize: 20; font.weight: Font.Bold; color: Theme.surfaceText; anchors.verticalCenter: parent.verticalCenter }
                        Rectangle {
                            width: planText.implicitWidth + 16; height: 24; radius: 12
                            anchors.verticalCenter: parent.verticalCenter
                            color: Theme.withAlpha(Theme.primary, 0.12)
                            StyledText { id: planText; anchors.centerIn: parent; text: root.plan || "Codex"; font.pixelSize: 11; color: Theme.primary }
                        }
                        Item { width: Math.max(0, parent.width - 24 - dashboardTitle.implicitWidth - planText.implicitWidth - 16 - closeChip.width - 32); height: 1 }
                        ActionChip { id: closeChip; label: "×"; onClicked: { if (dashboard.closePopout) dashboard.closePopout(); } }
                    }

                Row {
                    width: parent.width
                    spacing: 6
                    Rectangle {
                        width: 7; height: 7; radius: 4
                        anchors.verticalCenter: parent.verticalCenter
                        color: root.snapshotStale ? Theme.warning : Theme.primary
                    }
                    StyledText {
                        width: parent.width - refreshChip.width - 19
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.freshnessText
                        color: root.snapshotStale ? Theme.warning : Theme.surfaceVariantText
                        font.pixelSize: 12
                        elide: Text.ElideRight
                    }
                    ActionChip {
                        id: refreshChip
                        label: root.isLoading ? "Reading…" : "Refresh"
                        onClicked: {
                            if (!usageProcess.running) {
                                root.isLoading = true;
                                usageProcess.running = true;
                            }
                        }
                    }
                }

                DashboardCard {
                    visible: !root.loggedIn
                    width: parent.width; height: 72; radius: 16
                    StyledText {
                        anchors.fill: parent; anchors.margins: 16
                        text: root.isLoading ? "Reading Codex usage…" : "No Codex quota data is available. Sign in with codex login."
                        wrapMode: Text.WordWrap; font.pixelSize: 13
                        color: Theme.surfaceVariantText
                    }
                }

                Row {
                    width: parent.width
                    spacing: 12
                    visible: root.loggedIn
                    Repeater {
                        model: ["primary", "secondary"]
                        delegate: DashboardCard {
                            id: quotaCard
                            required property string modelData
                            property var bucket: root.buckets[modelData] || ({})
                            property bool recorded: bucket.REMAINING !== undefined
                            property bool estimated: bucket.ESTIMATED === "true"
                            property real used: recorded ? Math.max(0, Math.min(100, (1-bucket.REMAINING)*100)) : 0
                            property bool expired: bucket.RESET ? new Date(bucket.RESET).getTime() <= root.countdownNow : false
                            property real paceDelta: Number(bucket.PACE_DELTA || 0)
                            property color accent: used >= 80 ? Theme.error : (used >= 50 ? Theme.warning : (modelData === "primary" ? Theme.primary : Theme.secondary))
                            width: (parent.width - 12) / 2
                            height: root.isVertical ? 238 : 154; radius: 18
                            tint: accent
                            border.width: 1
                            border.color: Theme.withAlpha(accent, 0.22)
                            UsageRing {
                                id: quotaRing
                                anchors.left: root.isVertical ? undefined : parent.left
                                anchors.leftMargin: 16
                                anchors.horizontalCenter: root.isVertical ? parent.horizontalCenter : undefined
                                anchors.top: root.isVertical ? parent.top : undefined
                                anchors.topMargin: 14
                                anchors.verticalCenter: root.isVertical ? undefined : parent.verticalCenter
                                width: 80; height: 80
                                percent: quotaCard.used
                                pacePercent: quotaCard.used - quotaCard.paceDelta
                                showPace: root.showPacing && bucket.PACE !== undefined
                                accent: quotaCard.accent
                                opacity: quotaCard.recorded ? 1 : 0.35
                            }
                            Column {
                                anchors.left: root.isVertical ? parent.left : quotaRing.right
                                anchors.right: parent.right
                                anchors.leftMargin: root.isVertical ? 14 : 16
                                anchors.rightMargin: 14
                                anchors.top: root.isVertical ? quotaRing.bottom : undefined
                                anchors.topMargin: 12
                                anchors.verticalCenter: root.isVertical ? undefined : parent.verticalCenter
                                spacing: 8
                                StyledText {
                                    width: parent.width
                                    horizontalAlignment: root.isVertical ? Text.AlignHCenter : Text.AlignLeft
                                    text: quotaCard.bucket.LABEL || (quotaCard.modelData === "primary" ? "5h budget" : "Weekly limit")
                                    font.pixelSize: 15; font.weight: Font.DemiBold
                                    color: Theme.surfaceText
                                }
                                StyledText {
                                    width: parent.width
                                    horizontalAlignment: root.isVertical ? Text.AlignHCenter : Text.AlignLeft
                                    text: quotaCard.recorded ? (100-Math.round(quotaCard.used)) + "% remaining" : "Not recorded"
                                    font.pixelSize: 13; color: quotaCard.accent
                                }
                                StyledText {
                                    width: parent.width
                                    horizontalAlignment: root.isVertical ? Text.AlignHCenter : Text.AlignLeft
                                    text: quotaCard.expired
                                          ? (quotaCard.estimated ? "Five-hour session complete" : "Waiting for fresh data")
                                          : (quotaCard.bucket.RESET
                                             ? (quotaCard.estimated ? "Ends in " : "Reset in ") + root.countdown(quotaCard.bucket.RESET)
                                             : "Reset unavailable")
                                    font.pixelSize: 11
                                    color: quotaCard.expired ? Theme.warning : Theme.surfaceVariantText
                                    wrapMode: Text.WordWrap
                                }
                                StyledText {
                                    width: parent.width
                                    horizontalAlignment: root.isVertical ? Text.AlignHCenter : Text.AlignLeft
                                    visible: root.showPacing && text !== ""
                                    text: quotaCard.bucket.PACE || ""
                                    font.pixelSize: 11
                                    color: quotaCard.paceDelta >= 5 ? Theme.warning : Theme.surfaceVariantText
                                }
                                StyledText {
                                    width: parent.width
                                    horizontalAlignment: root.isVertical ? Text.AlignHCenter : Text.AlignLeft
                                    visible: quotaCard.estimated
                                    text: quotaCard.bucket.DESC || "Estimated from weekly quota change"
                                    font.pixelSize: 10; color: Theme.surfaceVariantText
                                    wrapMode: Text.WordWrap
                                }
                            }
                        }
                    }
                }

                Row {
                    width: parent.width
                    spacing: 10
                    Repeater {
                        model: [{label:"Today",value:root.stats.today || 0,cost:root.stats.today_cost || 0},{label:"7 days",value:root.stats.week || 0,cost:root.stats.week_cost || 0},{label:"This month",value:root.stats.month || 0,cost:root.stats.month_cost || 0}]
                        delegate: DashboardCard {
                            required property var modelData
                            required property int index
                            width: (parent.width - 20) / 3
                            height: 108
                            tint: index === 0 ? Theme.primary : (index === 1 ? Theme.secondary : Theme.tertiary)
                            Column {
                                anchors.fill: parent; anchors.margins: 12; spacing: 5
                                StyledText { text: modelData.label; color: Theme.surfaceVariantText; font.pixelSize: 11 }
                                StyledText { width: parent.width; text: root.compact(modelData.value); elide: Text.ElideRight; color: Theme.surfaceText; font.pixelSize: 22; font.weight: Font.Bold }
                                StyledText { text: root.money(modelData.cost) + " API eq."; color: Theme.primary; font.pixelSize: 10 }
                            }
                        }
                    }
                }

                Column {
                    width: parent.width
                    spacing: 12
                    visible: root.detailsExpanded

                    DashboardCard {
                        width: parent.width; height: 210; radius: 18
                        Column {
                            anchors.fill: parent; anchors.margins: 14; spacing: 8
                            Row {
                                width: parent.width
                                StyledText {
                                    text: "Activity"; width: parent.width - 112
                                    anchors.verticalCenter: parent.verticalCenter
                                    font.pixelSize: 14; font.weight: Font.DemiBold; color: Theme.surfaceText
                                }
                                ActionChip { label: "7d"; selected: root.chartDays === 7; onClicked: root.savePreference("chartDays", 7) }
                                ActionChip { label: "30d"; selected: root.chartDays === 30; onClicked: root.savePreference("chartDays", 30) }
                            }
                            StyledText {
                                text: root.hoveredDay || (root.chartDays === 7 ? root.weekTrend : "Daily tokens · last 30 days")
                                width: parent.width; elide: Text.ElideRight
                                font.pixelSize: 12; color: root.hoveredDay ? Theme.primary : Theme.surfaceVariantText
                            }
                            Row {
                                width: parent.width; spacing: root.chartDays === 7 ? 8 : 3
                                Repeater {
                                    model: root.chartData
                                    delegate: Column {
                                        required property var modelData
                                        required property int index
                                        width: (parent.width - parent.spacing * (root.chartData.length - 1)) / Math.max(1, root.chartData.length)
                                        spacing: 6
                                        Item {
                                            width: parent.width; height: 94
                                            Rectangle {
                                                anchors.bottom: parent.bottom
                                                width: parent.width
                                                height: modelData.tokens > 0 ? Math.max(3, 94 * modelData.tokens / root.maxDaily) : 2
                                                radius: Math.min(4, width / 2)
                                                color: dayHover.containsMouse || index === root.chartData.length - 1 ? Theme.primary : Theme.withAlpha(Theme.primary, 0.36)
                                                Behavior on height { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
                                            }
                                            MouseArea {
                                                id: dayHover
                                                anchors.fill: parent; hoverEnabled: true
                                                onEntered: root.hoveredDay = modelData.date + " · " + Number(modelData.tokens).toLocaleString(Qt.locale(), 'f', 0) + " tokens · " + root.money(modelData.cost) + " API eq."
                                                onExited: root.hoveredDay = ""
                                            }
                                        }
                                        StyledText {
                                            anchors.horizontalCenter: parent.horizontalCenter
                                            text: root.chartDays === 7 ? modelData.day : ((index === 0 || index === 14 || index === 29) ? modelData.date.slice(8) : "")
                                            font.pixelSize: 10; color: Theme.surfaceVariantText
                                        }
                                    }
                                }
                            }
                        }
                    }

                    DashboardCard {
                        width: parent.width; height: modelColumn.implicitHeight + 28; radius: 18
                        tint: Theme.secondary
                        Column {
                            id: modelColumn
                            anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
                            anchors.margins: 14; spacing: 10
                            StyledText { text: "Top models · 7 days"; font.pixelSize: 14; font.weight: Font.DemiBold; color: Theme.surfaceText }
                            StyledText { visible: !(root.stats.models || []).length; text: "No local token activity yet"; font.pixelSize: 12; color: Theme.surfaceVariantText }
                            Repeater {
                                model: root.stats.models || []
                                delegate: Row {
                                    required property var modelData
                                    width: modelColumn.width
                                    spacing: 10
                                    StyledText {
                                        text: modelData.name
                                        width: (parent.width - 126) * 0.58
                                        elide: Text.ElideRight
                                        font.pixelSize: 12; color: Theme.surfaceText
                                        anchors.verticalCenter: parent.verticalCenter
                                    }
                                    Rectangle {
                                        width: (parent.width - 126) * 0.42
                                        height: 4; radius: 2; color: Theme.surfaceVariant
                                        anchors.verticalCenter: parent.verticalCenter
                                        Rectangle {
                                            width: parent.width * Math.min(1, modelData.tokens / Math.max(1, root.stats.week || 0))
                                            height: 4; radius: 2; color: Theme.secondary
                                            Behavior on width { NumberAnimation { duration: 220 } }
                                        }
                                    }
                                    StyledText {
                                        text: root.compact(modelData.tokens) + " · " + root.money(modelData.cost)
                                        width: 106; horizontalAlignment: Text.AlignRight
                                        font.pixelSize: 12; color: Theme.surfaceVariantText
                                        anchors.verticalCenter: parent.verticalCenter
                                    }
                                }
                            }
                            StyledText {
                                width: parent.width
                                text: root.breakdownText
                                font.pixelSize: 11; color: Theme.surfaceVariantText; wrapMode: Text.WordWrap
                            }
                        }
                    }
                }
                Row {
                    width: parent.width; spacing: 6
                    ActionChip {
                        label: root.detailsExpanded ? "Less detail ↑" : "More detail ↓"
                        selected: root.detailsExpanded
                        onClicked: root.savePreference("detailsExpanded", !root.detailsExpanded)
                    }
                    ActionChip {
                        label: root.alertsEnabled ? "Alerts on · 80/90%" : "Alerts off"
                        selected: root.alertsEnabled
                        onClicked: root.savePreference("alertsEnabled", !root.alertsEnabled)
                    }
                }

                StyledText {
                    width: parent.width
                    text: root.valueText()
                    font.pixelSize: 12; font.weight: Font.Medium; color: Theme.primary
                    horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap
                }

                StyledText {
                    width: parent.width
                    text: "Local token estimate · " + (root.stats.sessions || 0) + " sessions / 7 days · " + (root.liveData ? "Live Codex quota" : "Cached Codex quota")
                    font.pixelSize: 11; color: Theme.surfaceVariantText
                    horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap
                }
                Item { width: 1; height: 4 }
                }
            }
        }
    }
}
