# Match Point GPT

En fristående macOS-pilot för tennisbevakning.

Tanken är inte att kopiera Match Point, utan att prova ett mer analytiskt gränssnitt:

- live och kommande matcher från Oddset
- spelar- och formdata från ATP-databasen
- en “radar”-vy som lyfter fram signaler, risker och momentum

## Köra

```bash
swift run MatchPointGPT
```

## Bygga app

```bash
Scripts/build-app.sh debug --install
```

Databasinställningar läses från samma UserDefaults-nycklar som Match Point, eller från miljövariablerna:

- `MYSQL_HOST`
- `MYSQL_PORT`
- `MYSQL_DATABASE`
- `MYSQL_USER`
- `MYSQL_PASSWORD`

När appen körs som `.app` läser den även:

```text
~/Library/Application Support/Match Point GPT/.env
```

Filen ska innehålla samma nycklar som ovan och hålls utanför repositoryt.
