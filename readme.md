# YOU ARE RESPONSIBLE FOR YOUR OWN DATA.

This container runs a database repair tool that modifies your Plex SQLite database.
Always ensure you have working backups before proceeding.

About This Container
This Docker container is provided to assist users in running the Plex database repair tool to resolve common Plex database issues.
It wraps and automates the excellent repair script created by ChuckPa:

Project: https://github.com/ChuckPa/DBRepair
Please review the main project documentation to understand what the tool does and when it should be used.

What This Container Does
* Runs DBRepair.sh inside a controlled Docker environment
* Provides a real TTY using expect (required by the script)
* Automatically responds to required prompts
* Emits heartbeat status messages while the repair is running
* Writes a persistent log file and mirrors output to Docker logs
* Exits automatically when the repair completes

