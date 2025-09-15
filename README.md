# jellyfin-tag-editor
Interactive CLI tool to bulk edit tags for jellyfin libraries

An interactive, dependency-light Bash script that bulk adds/removes a tag from all items in a selected Jellyfin library.

Dependencies: bash, curl, jq
(No fzf/dialog needed — it’s pure TTY prompts.)

You can pass connection details as environment variables by editing the provided .env.sample file and renaming it to .env
