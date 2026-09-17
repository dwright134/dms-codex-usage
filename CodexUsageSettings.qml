import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

PluginSettings {
    id: root
    pluginId: "codexusage"

    Rectangle {
        width: parent.width
        implicitHeight: heading.implicitHeight + Theme.spacingM * 2
        radius: Theme.cornerRadius
        color: Theme.surfaceContainerHigh

        Column {
            id: heading
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Theme.spacingM
            spacing: Theme.spacingXS

            Row {
                spacing: Theme.spacingS
                DankIcon { name: "terminal"; size: 24; color: Theme.primary }
                StyledText {
                    text: "Codex Usage"
                    font.pixelSize: Theme.fontSizeLarge
                    font.weight: Font.DemiBold
                    color: Theme.primary
                }
            }
            StyledText {
                width: parent.width
                text: "Live quota pacing, a synthetic five-hour budget, token activity, and estimated API-equivalent value."
                wrapMode: Text.WordWrap
                color: Theme.surfaceVariantText
                font.pixelSize: Theme.fontSizeSmall
            }
        }
    }

    ToggleSetting {
        settingKey: "showIcon"
        label: "Bar icon"
        description: "Show the terminal icon beside your usage on horizontal and vertical bars."
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "showPacing"
        label: "Show pacing"
        description: "Compare quota use with an even burn rate through each window."
        defaultValue: true
    }

    StringSetting {
        settingKey: "subscriptionCost"
        label: "Monthly subscription cost (USD)"
        description: "Used only to compare your estimated API-equivalent value with your plan cost."
        placeholder: "20"
        defaultValue: "20"
    }

    SelectionSetting {
        settingKey: "refreshSeconds"
        label: "Refresh interval"
        description: "How often to refresh live limits and local Codex activity."
        defaultValue: "30"
        options: [
            {label: "15 seconds", value: "15"},
            {label: "30 seconds", value: "30"},
            {label: "1 minute", value: "60"},
            {label: "5 minutes", value: "300"}
        ]
    }

    StyledText {
        text: "Dashboard"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.DemiBold
        color: Theme.primary
    }

    SelectionSetting {
        settingKey: "chartDays"
        label: "Activity history"
        description: "Choose the time range for the token activity chart."
        defaultValue: "7"
        options: [
            {label: "Last 7 days", value: "7"},
            {label: "Last 30 days", value: "30"}
        ]
    }

    ToggleSetting {
        settingKey: "detailsExpanded"
        label: "Show activity details"
        description: "Expand the activity and model breakdown in the dashboard."
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "alertsEnabled"
        label: "Usage alerts"
        description: "Show a warning at 80% and 90% usage for the five-hour budget and weekly limit."
        defaultValue: false
    }
}
