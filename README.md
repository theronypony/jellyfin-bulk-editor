# jellyfin-bulk-editor

Interactive CLI tools to bulk edit tags and users in Jellyfin

An interactive, dependency-light Bash script that bulk adds/removes metadata in Jellyfin.

With these scripts you can interactively update:

Library: Item Tags
Users: Library Access, Allow Tags, Block Tags


Dependencies: bash, curl, jq

You can pass connection details as environment variables by editing the provided .env.sample file and renaming it to .env
