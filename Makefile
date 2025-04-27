date := $(shell date --utc +'%Y-%m-%d %H:%M:%S')

# Build web page
build/locked.html: head.html build/locked.txt build/tail.html
	awk 'ORS="";{print "<tr><td>" FNR "</td><td><a href=\"https://dearrow.minibomba.pro/user_id/" $$1 "\">" gensub(/\\''/, "\\&#39;", "g", gensub(/"/, "\\&quot;", "g", gensub(/>/, "\\&gt;", "g", gensub(/</, "\\&lt;", "g", $$3)))) "</a></td><td>" $$2 "</td></tr>"}' \
	build/locked.txt \
	| cat head.html - tail.html > build/locked.html

# Download report messages from Discord
build/locked-titles.json build/tail.html &:
	sed "s/\\\$$DATE\\\$$/${date}/" tail.html > build/tail.html
	DiscordChatExporter.Cli export -c 1167321798178766968 -f json -o build/locked-titles.json --media False

# Count by user ID
build/by-id: build/locked-titles.json
	< build/locked-titles.json jq -r '.messages | map(select(.author.id == "1167323752363733074")) | map(.embeds.[0].description) | .[]' > build/embeds
	rg --multiline --no-line-number -o --replace='$$1' '\*\*Submitted by:\*\* [^\n]*\n([^\n]*)' build/embeds > build/report-users
	awk '{count[$$1]++} END{for (a in count) print count[a], a}' build/report-users | sort -nr | awk '{print $$2, $$1} NR==20{exit}' > build/by-id

# Fetch usernames
build/locked.txt: build/by-id
	awk '{print $$1}' build/by-id | xargs -I{} -n1 curl -sS https://sponsor.ajay.app/api/userInfo?publicUserID={} -w '\n'\
	| jq -r '.userName' > build/usernames
	awk 'FNR==NR {a[FNR]=$$1;next}{ print $$1, $$2, a[FNR]}' build/usernames build/by-id > build/locked.txt
