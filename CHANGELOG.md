## Change log

2026-11-16: v3.2.1 - Prepare for general use: remove the development-only demo notification. The installer package now also installs a LaunchAgent (/Library/LaunchAgents/com.jamf.cloudmonitor.plist) so jamfStatus starts at login for all users, and restarts the app after an upgrade.

2026-11-16: v3.2.0 - Add Jamf Pro notification alerts. When an instance has unacknowledged notifications its status light and the menu bar icon turn red, and a popup lists them by server every 15 minutes. Each server can be acknowledged or ignored for 1 hour independently (or all at once). Acknowledged notifications remain listed in the menu, marked green. Click a notification, or choose Notifications…, to open the popup from the menu. Add a Help menu. Updated by Russell Collis.

2026-11-16: v3.1.0 - Add support for monitoring multiple Jamf Pro instances. Instances are added, edited, and removed from Settings → Server, each with its own name, URL, authentication type, and credentials. The menu shows a status light for each instance (click to open the instance in a browser), each instance's notifications are listed directly under it, and the Health Status window includes an instance picker. Existing single-server settings are migrated automatically.

2026-06-26: v3.0.0 - Significant code update. Resolve crash that could occur when trying to edit app settings.

2025-01-19: v2.5.4 - Better handling of the health status window.

2025-01-15: v2.5.3 - Actively update health status window if it is presented.

2025-12-24: v2.5.1 - Log health status rates below 1.0.

2025-12-21: v2.5.0 - Add basic hardware, OS, and jamfStatus app usage collection. Data is sent anonymously to [TelemetryDeck](https://telemetrydeck.com) to aid in the development of the app. View 'About...' to opt out of sending the data. Add ability to view health-status for Jamf Cloud hosted instances. Fix an issue with token renewal.

2023-12-06: v2.4.1 - Minor updates to the alerts display.

2023-11-11: v2.4.0 - Fix issue with notifications not being displayed.  Add ability to use API client.

2023-04-07: v2.3.6 - Update logging to prevent potential looping.  

2022-10-02: v2.3.2 - Rework authentication/token refresh.

2022-06-12: v2.3.1 - Clean up notificatations not displaying properly.

2021-10-15: v2.3.0 - Updated notifications display.
