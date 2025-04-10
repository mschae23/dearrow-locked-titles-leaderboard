#!/usr/bin/bash

mkdir -p /tmp/dearrow-locked-titles-leaderboard

date --utc +'%Y-%m-%d %H:%M:%S' > /tmp/dearrow-locked-titles-leaderboard/date
DiscordChatExporter.Cli export -c 1167321798178766968 -o locked-titles.json -f json --media False || exit

# Count by user ID
< locked-titles.json jq -r '.messages | map(select(.author.id == "1167323752363733074")) | map(.embeds.[0].description) | .[]' > /tmp/dearrow-locked-titles-leaderboard/embeds
rg --multiline --no-line-number -o --replace='$1' '\*\*Submitted by:\*\* [^\n]*\n([^\n]*)' /tmp/dearrow-locked-titles-leaderboard/embeds > /tmp/dearrow-locked-titles-leaderboard/report-users
awk '{count[$1]++} END{for (a in count) print count[a], a}' /tmp/dearrow-locked-titles-leaderboard/report-users | sort -nr | awk '{print $2, $1} NR==20{exit}' > /tmp/dearrow-locked-titles-leaderboard/by-id

# Fetch usernames
awk '{print $1}' /tmp/dearrow-locked-titles-leaderboard/by-id | xargs -I{} -n1 curl -sS https://sponsor.ajay.app/api/userInfo?publicUserID={} -w '\n' | jq -r '.userName' > /tmp/dearrow-locked-titles-leaderboard/usernames
sed -i.bak -f replace /tmp/dearrow-locked-titles-leaderboard/usernames
awk 'FNR==NR {a[FNR]=$1;next}{ print $1, $2, a[FNR]}' /tmp/dearrow-locked-titles-leaderboard/usernames /tmp/dearrow-locked-titles-leaderboard/by-id > locked-titles-leaderboard

# Replace date in template
sed "s/\\\$DATE\\\$/$(cat /tmp/dearrow-locked-titles-leaderboard/date)/" tail.html > /tmp/dearrow-locked-titles-leaderboard/tail.html

# Build website
awk 'ORS="";{print "<tr><td>" FNR "</td><td><a href=\"https://dearrow.minibomba.pro/user_id/" $1 "\">" $3 "</a></td><td>" $2 "</td></tr>"}' locked-titles-leaderboard | cat head.html - /tmp/dearrow-locked-titles-leaderboard/tail.html > locked.html
