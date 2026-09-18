# Varseltekster

## Kodifisert varselmal — utkast til gjennomgang

Dette er arbeidsstrukturen for alle værtyper. Måleverdier oversettes først
til en kort tekst fra tabellene under. Råverdier kan legges til senere dersom
de er nyttige, men skal ikke være hovedteksten.

### Første linje

```text
Det blir [Værtype]! [sted] [tid]
```

Eksempler: `Det blir Regn! på Klinga om tre timer.` ·
`Det blir Sol! oppi Selbu i morgen.`

`Værtype` har stor forbokstav og utropstegn. `tid` bruker kort språk:
«om en halvtime», «om tre timer», «i dag», «i kveld», «i natt», «i morgen»
eller «til helga». Stedet beholder valgt preposisjon.

### Språkverdier for malen

| Nøkkel | Bokmål | Inntrøndersk | English |
|---|---|---|---|
| Første linje | Det blir {Værtype}! {sted} {tid}. | D bli {Værtype}! {sted} {tid}. | It will be {WeatherType}! {place} {time}. |
| Sikker beskrivelse | Litt regn | Litt regn | Light rain |
| Kraftig regn | Kraftig regn | Kraftig regn | Heavy rain |
| Lett snø | Lett snøfall | Lætt snøfall | Light snowfall |
| Kraftig snø | Kraftig snøfall | Kraftig snøfall | Heavy snowfall |
| Frisk vind | Frisk bris | Frisk bris | Fresh breeze |
| Sterk vind | Sterk vind | Sterk vind | Strong wind |
| Kort varighet | en liten stund | ei lita stund | briefly |
| Gjennom natta | gjennom natta | gjennom natta | through the night |

De samme språkverdiene ligger i `Sprak.json` under `template.*` og
`detail.*`. Tabellen her er lesbar arbeidsreferanse; JSON-filen er kilden som
senere skal kobles til alle visningene.

### Andre linje

```text
[Beskrivelse] [dag/tid], kl. [TT] — [varighet]
```

Eksempler: `Kraftig regn i morgen, lørdag kl. 10 — i to timer.` ·
`Lett snøfall i natt kl. 02 — gjennom natta.` ·
`Frisk bris til helga, søndag kl. 14 — i tre timer.`

Ved nært varsel kan andre linje være kort: `Litt regn om en halvtime — i 20 minutter.`

Varigheten skal også være tekstbasert: «en liten stund», «i 20 minutter»,
«i to timer», «gjennom natta» eller «store deler av dagen». Unngå rått
timeantall når en naturlig formulering er bedre. Kortvarig betyr her forventet
varighet under én time; da kan varighetsleddet sløyfes når det ikke tilfører
ny informasjon.

### Teksttabeller — første utkast

#### Regn

| Grunnlag i varselperioden | Tekst |
|---|---|
| Svært lite / spredte dråper | Yr eller litt regn |
| Lite nedbør | Litt regn |
| Jevnt moderat nedbør | Regn |
| Stor mengde eller langvarig nedbør | Kraftig regn |
| Korte, avgrensede perioder | Regnbyger |

#### Snø

| Grunnlag i varselperioden | Tekst |
|---|---|
| Svært lite snø | Enkelte snøfnugg |
| Lite snøfall | Lett snøfall |
| Jevnt snøfall | Snøfall |
| Stor mengde eller tett snø | Kraftig snøfall |
| Korte, avgrensede perioder | Snøbyger |
| Blanding av regn og snø | Sludd |

#### Vindkast (forenklet Beaufort-ordbok)

| Vindkast | Tekst |
|---:|---|
| Under 5 m/s | Lette vindkast |
| 5–9 m/s | Frisk bris |
| 10–16 m/s | Kraftige vindkast |
| 17–23 m/s | Sterk vind |
| 24 m/s eller mer | Stormkast |

#### Dugg og frost

| Tilstand | Tekst |
|---|---|
| Duggpunkt nær lufttemperaturen | Fare for dugg |
| Duggfall er nært forestående | Duggfall |
| Lokal frostmargin slår til | Fare for frost |
| Temperatur faktisk 0 °C eller lavere | Frost |

#### Sol og temperatur

| Tilstand | Tekst |
|---|---|
| Lavt skydekke i kortere gløtt | Solgløtt |
| Lang periode med lite skydekke | Sol |
| Temperatur under valgt grense | Under [X]° |
| Temperatur over valgt grense | Over [X]° |

Disse tabellene er et språk- og tekstutkast. Tersklene finjusteres etter at
Mathias har gått gjennom formuleringene og sett dem i appen.

Referanse for komplette tekster på tvers av iPhone, Apple Watch og CarPlay.
Hver værtype har samme rekkefølge: app-push, nåstatus, Watch og CarPlay.
CarPlay kan vise flere korte linjer: først stedene, deretter nærmeste
hendelse og så neste hendelse.

«Inline-komplikasjon», «rund komplikasjon» og «hjørnekomplikasjon» gjelder
Apple Watch. CarPlay bruker i stedet en CarPlay-widget fra iPhone-widgeten,
vanligvis den lille systemwidgeten.

## Duggfall

| Situasjon | Full tekst |
|---|---|
| **App push-varsel** |  |
| Sikkert pushvarsel | **Det blir Duggfall! på Klinga i morgen.**<br>Duggfall i morgen, onsdag kl. 05 — gjennom natta. |
| Usikkert pushvarsel | **Det kan bli Duggfall! på Klinga i morgen.**<br>Mulig duggfall i morgen, onsdag kl. 05 — en liten stund. |
| **Nåstatus i app** |  |
| Pågår nå | **D e Duggfall!**<br>Duggpunktet er nær lufttemperaturen. |
| **Apple Watch** |  |
| Rund komplikasjon (klokkesirkel) | **Dogg!** · 45 m |
| Inline-widget | **Dogg! 45m** |
| Hjørnekomplikasjon | Værikon med «Dogg!» som hjelpetekst |
| Stor/rektangulær widget | **Klinga 8°**<br>**Neste 12 timer**<br>Dogg! om 45 m |
| **CarPlay-widget** |  |
| CarPlay-widget | **D bli Vær! på Klinga**<br>Også oppå Hornburu.<br>Doggfall i natt.<br>Regn om 3 timer. |

## Regn

| Situasjon | Full tekst |
|---|---|
| **App push-varsel** |  |
| Sikkert pushvarsel | **Det blir Regn! nerri Namsos i morgen.**<br>Litt regn i morgen, mandag kl. 06 — en liten stund. |
| Usikkert pushvarsel | **Det kan bli Regn! nerri Namsos i morgen.**<br>Mulig regn i morgen, mandag kl. 06 — en liten stund. |
| **Nåstatus i app** |  |
| Pågår nå | **D Regne!**<br>0,2 mm i Nå-varselet den neste halvtimen. |
| **Apple Watch** |  |
| Rund komplikasjon (klokkesirkel) | **Regn!** · 23 m |
| Inline-widget | **Regn! 23m** |
| Hjørnekomplikasjon | Regnikon med «Regn!» som hjelpetekst |
| Stor/rektangulær widget | **Klinga 12°**<br>**Neste 12 timer**<br>Regn! om 23 m |
| **CarPlay-widget** |  |
| CarPlay-widget | **D bli Vær! på Klinga**<br>Også oppå Hornburu.<br>Regn om 23 m.<br>Doggfall i natt. |

## Snø

| Situasjon | Full tekst |
|---|---|
| **App push-varsel** |  |
| Sikkert pushvarsel | **Det blir Snø! oppi Bangdalen i natt.**<br>Lett snøfall i natt, tirsdag kl. 02 — gjennom natta. |
| Usikkert pushvarsel | **Det kan bli Snø! oppi Bangdalen i natt.**<br>Mulig snø i natt, tirsdag kl. 02 — en liten stund. |
| **Nåstatus i app** |  |
| Pågår nå | **Det Snør!**<br>Snø i Nå-varselet den neste halvtimen. |
| **Apple Watch** |  |
| Rund komplikasjon (klokkesirkel) | **Snø!** · 2 t |
| Inline-widget | **Snø! 2t** |
| Hjørnekomplikasjon | Snøikon med «Snø!» som hjelpetekst |
| Stor/rektangulær widget | **Bangdalen 3°**<br>**Neste 12 timer**<br>Snø! om 2 t |
| **CarPlay-widget** |  |
| CarPlay-widget | **D bli Vær! oppi Bangdalen**<br>Snø om 2 timer.<br>Regn senere i kveld. |

## Frost

| Situasjon | Full tekst |
|---|---|
| **App push-varsel** |  |
| Sikkert pushvarsel | **Det blir Frost! på Klinga i natt.**<br>Frost i natt, tirsdag kl. 04 — gjennom natta. |
| Usikkert pushvarsel | **Det kan bli Frost! på Klinga i natt.**<br>Fare for frost i natt, tirsdag kl. 04 — en liten stund. |
| **Nåstatus i app** |  |
| Pågår nå | **D e Frost!**<br>Lokalt anslag er under frostgrensen. |
| Temperaturgrense | **D bli Under 5°! på Klinga**<br>Temperaturen kan gå under 5° i natt — tirsdag kl. 03. |
| **Apple Watch** |  |
| Rund komplikasjon (klokkesirkel) | **Frost!** · 1 t |
| Inline-widget | **Frost! 1t** |
| Hjørnekomplikasjon | Frostikon med «Frost!» som hjelpetekst |
| Stor/rektangulær widget | **Klinga 2°**<br>**Neste 12 timer**<br>Frost! om 1 t |
| **CarPlay-widget** |  |
| CarPlay-widget | **D bli Vær! på Klinga**<br>Frost om 1 time.<br>Regn i natt. |

## Vindkast

| Situasjon | Full tekst |
|---|---|
| **App push-varsel** |  |
| Sikkert pushvarsel | **Det blir Vind! bortpå Klinga i morgen.**<br>Frisk bris i morgen, mandag kl. 10 — i tre timer. |
| Sterkere vind | **Det blir Vind! bortpå Klinga i kveld.**<br>Sterk vind i kveld, mandag kl. 19 — i tre timer. |
| **Nåstatus i app** |  |
| Pågår nå | **D Blæs!**<br>Vindkast 9 m/s akkurat nå. |
| **Apple Watch** |  |
| Rund komplikasjon (klokkesirkel) | **Vind!** · 23 m |
| Inline-widget | **Vind! 23m** |
| Hjørnekomplikasjon | Vindikon med «Vind!» som hjelpetekst |
| Stor/rektangulær widget | **Klinga 12°**<br>**Neste 12 timer**<br>Vind! om 23 m |
| **CarPlay-widget** |  |
| CarPlay-widget | **D bli Vær! på Klinga**<br>Vindkast om 23 minutter.<br>Doggfall i natt. |

## Sol

I solvarsler betyr «om» når solperioden starter, mens «i» beskriver hvor
lenge den varer. Derfor er «Sol om 4 timer» en startbeskjed, mens «Sol i fire
timer» er varigheten.

| Situasjon | Full tekst |
|---|---|
| **App push-varsel** |  |
| Sikkert pushvarsel | **Det blir Sol! inni Hornburu i morgen.**<br>Sol i morgen, fredag kl. 12 — store deler av dagen. |
| Usikkert pushvarsel | **Det kan bli Sol! inni Hornburu i morgen.**<br>Solgløtt i morgen, fredag kl. 12 — i fire timer. |
| **Nåstatus i app** |  |
| Pågår nå | **D e Sol!**<br>Solforholdene er gode nå. |
| **Apple Watch** |  |
| Rund komplikasjon (klokkesirkel) | **Sol!** · 4 t |
| Inline-widget | **Sol! 4t** |
| Hjørnekomplikasjon | Solikon med «Sol!» som hjelpetekst |
| Stor/rektangulær widget | **Hornburu 14°**<br>**Neste 12 timer**<br>Sol! om 4 t |
| **CarPlay-widget** |  |
| CarPlay-widget | **D bli Vær! oppå Hornburu**<br>Sol om 4 timer.<br>Regn i natt. |

## Temperatur

| Situasjon | Full tekst |
|---|---|
| **App push-varsel** |  |
| Under grense | **Det blir Under 10°! nerri Namsos i natt.**<br>Under 10° i natt, tirsdag kl. 02 — gjennom natta. |
| Over grense | **Det blir Over 20°! på Klinga i morgen.**<br>Over 20° i morgen, onsdag kl. 14 — i tre timer. |
| **Nåstatus i app** |  |
| Pågår nå | **D e Under 10°!**<br>Det er under 10° nå. |
| **Apple Watch** |  |
| Rund komplikasjon (klokkesirkel) | **<10°** · 1 t |
| Inline-widget | **<10° 1t** |
| Hjørnekomplikasjon | Temperaturikon med «<10°» som hjelpetekst |
| Stor/rektangulær widget | **Namsos 8°**<br>**Neste 12 timer**<br><10° om 1 t |
| **CarPlay-widget** |  |
| CarPlay-widget | **D bli Vær! nerri Namsos**<br>Under 10° om 1 time.<br>Regn i morgen. |

## Rene appvarsler

| Situasjon | Full tekst |
|---|---|
| App push-varsel | **D bli Vær!**<br>Appen må startes for å aktivere varsler. |
| Nåstatus i app | **D bli Vær!**<br>Ingen aktive værhendelser akkurat nå. |

## Språkregel

«D e [værtype]!» brukes når værtypen faktisk pågår. «D bli Regn!» brukes for
et framtidig sikkert varsel. «D kan bli Regn!» brukes når varselet er usikkert.
