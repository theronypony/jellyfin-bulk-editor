# jellyfin-tag-editor
Interactive CLI tool to bulk edit tags for jellyfin libraries

An interactive, dependency-light Bash script that bulk adds/removes a tag from all items in a selected Jellyfin library.

Dependencies: bash, curl, jq
(No fzf/dialog needed — it’s pure TTY prompts.)

You can pass connection details as flags or let the script prompt you:

--server https://jf.example.com

--api-key YOUR_API_KEY

--user-id YOUR_USER_ID

Save as jf-bulk-tag-interactive.sh and chmod +x it.
