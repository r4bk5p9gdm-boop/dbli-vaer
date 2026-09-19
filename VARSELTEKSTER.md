# Varseltekster — første gjennomgang

Dette er arbeidsdokumentet for pushvarsel, Varsler-siden, nåstatus, Apple
Watch og CarPlay. Her gjennomgår vi **bokmål** og **inntrøndersk**. Engelsk er
på vent og beholdes foreløpig uendret i `Sprak.json`.

Målet er at første linje skal være umiddelbart forståelig, mens andre linje
gir konkret værbeskrivelse, tidspunkt og ved behov varighet — uten gjentakelse.

## Fast oppbygning

| Del | Bokmål | Inntrøndersk |
|---|---|---|
| Sikkert framtidsvarsel | `Det blir {Værtype}! {sted} {tid}.` | `D bli {Værtype}! {sted} {tid}.` |
| Usikkert framtidsvarsel | `Det kan bli {Værtype}! {sted} {tid}.` | `D kan bli {Værtype}! {sted} {tid}.` |
| Andre linje | `{Beskrivelse} {dag/klokkeslett} — {varighet}.` | `{Beskrivelse} {dag/klokkeslett} — {varighet}.` |

`{sted}` er brukerens valgte preposisjon + stedsnavn: «på Klinga», «inni
Hornburu» eller «nerri Namsos». Preposisjonen oversettes aldri automatisk.

## Tid og varighet

| Når hendelsen starter | Første linje | Andre linje |
|---|---|---|
| Under én time fram | `om et kvarter` / `om en halvtime` / `om 45 minutter` | Bare værdetalj; klokkeslett er normalt overflødig. |
| Senere i dag eller kveld | `i dag` / `i kveld` | `kl. 16` / `kl. 21` |
| Natt, før kl. 06 | `i natt` | `kl. 02` |
| I morgen | `i morgen` / `i mårrå` | `lørdag kl. 10` / `lørda'n kl. 10` |
| Overmorgen | `i overmorgen` / `i overmårrå` | `søndag kl. 14` / `sønda'n kl. 14` |
| Helgevarsel | `til helga` / `te helga` | `lørdag kl. 10` / `lørda'n kl. 10` |

Andre linje gjentar aldri «i morgen», «i natt» eller «til helga». Den går rett
på ukedag når hendelsen er en annen dag, og rett på klokkeslett når det er
samme dag, kveld eller natt.

| Forventet varighet | Bokmål | Inntrøndersk | Bruk |
|---|---|---|---|
| Under én time | utelates normalt | utelates normalt | Starttid + værtype holder. |
| 1–4 timer | `i to timer` | `i to tima` | Ta med når varigheten hjelper. |
| Mesteparten av natten | `gjennom natta` | `gjennom natta` | Bare når perioden dekker mesteparten av 23–07. |
| Hele natten | `hele natta` | `hele natta` | Bare når perioden dekker omtrent hele 23–07. |
| Lang dagperiode | `store deler av dagen` | `store dela av dagen` | Særlig for sol. |

«Gjennom natta» betyr altså ikke bare at været starter om natten. Det brukes
først når modellen forventer vær over mesteparten av natta.

## Ordbok for andre linje

### Regn

| Grunnlag | Bokmål | Inntrøndersk |
|---|---|---|
| Svært lite / dråper | Yr | Yr |
| Lite nedbør | Litt regn | Litt regn |
| Jevn nedbør | Regn | Regn |
| Mye eller langvarig nedbør | Kraftig regn | My regn |
| Korte, avgrensede perioder | Regnbyger | Regnbyga |

### Snø

| Grunnlag | Bokmål | Inntrøndersk |
|---|---|---|
| Enkelte fnugg | Enkelte snøfnugg | Nånn snøfnugg |
| Lite snøfall | Lett snøfall | Lætt snøfall |
| Jevnt snøfall | Snøfall | Snøfall |
| Tett eller mye snø | Kraftig snøfall | Kraftig snøfall |
| Korte perioder | Snøbyger | Snøbyga |
| Regn og snø samtidig | Sludd | Sludd |

### Vindkast

Vindvarsler og vindraden bygger på **vindkast**. Midlere vind kan ligge i en
presisering senere, men er ikke hovedordet i varselet.

| Vindkast | Bokmål | Inntrøndersk |
|---:|---|---|
| 8–12 m/s | Vindkast | Vindkasta |
| 13–17 m/s | Frisk bris | Frisk bris |
| 18–23 m/s | Sterke vindkast | Sterke vindkasta |
| 24 m/s eller mer | Stormkast | Stormkasta |

### Duggfall, frost, sol og temperatur

| Tilstand | Bokmål | Inntrøndersk |
|---|---|---|
| Duggpunkt innenfor lokal duggmargin | Fare for dugg | Fare for doggfall |
| Duggfall forventes | Duggfall ved {temperatur}° | Doggfall ved {temperatur}° |
| Lokal frostmargin slår til over 0° | Fare for frost | Fare for frost |
| 0° eller kaldere | Frost | Frost |
| Kort gløtt med lavt skydekke | Solgløtt | Solgløtt |
| Sammenhengende solperiode | Sol | Sol |
| Under valgt temperatur | Under {temperatur}° | Under {temperatur}° |
| Over valgt temperatur | Over {temperatur}° | Over {temperatur}° |

`Sol om fire timer` betyr starttid. `Sol i fire timer` betyr varighet. De to
uttrykkene kan derfor godt ha ulike tall.

## Fullstendige push-eksempler

### Regn

| Situasjon | Bokmål | Inntrøndersk |
|---|---|---|
| Sikkert, i morgen | **Det blir Regn! nerri Namsos i morgen.**<br>Litt regn mandag kl. 06 — i to timer. | **D bli Regn! nerri Namsos i mårrå.**<br>Litt regn manda'n kl. 06 — i to tima. |
| Usikkert, nært | **Det kan bli Regn! på Klinga om en halvtime.**<br>Yr. | **D kan bli Regn! på Klinga om en halvtime.**<br>Yr. |
| Kraftig, i natt | **Det blir Regn! oppi Bangdalen i natt.**<br>Kraftig regn kl. 02 — gjennom natta. | **D bli Regn! oppi Bangdalen i natt.**<br>My regn kl. 02 — gjennom natta. |
| Pågår nå | **Det regner!**<br>Litt regn den neste halvtimen. | **D regne!**<br>Litt regn den neste halvtimen. |

### Snø

| Situasjon | Bokmål | Inntrøndersk |
|---|---|---|
| Sikkert, i natt | **Det blir Snø! oppi Bangdalen i natt.**<br>Lett snøfall kl. 02 — gjennom natta. | **D bli Snø! oppi Bangdalen i natt.**<br>Lætt snøfall kl. 02 — gjennom natta. |
| Usikkert, i morgen | **Det kan bli Snø! oppi Selbu i morgen.**<br>Snøfall lørdag kl. 07 — i to timer. | **D kan bli Snø! oppi Selbu i mårrå.**<br>Snøfall lørda'n kl. 07 — i to tima. |
| Pågår nå | **Det snør!**<br>Snø den neste halvtimen. | **Det snør!**<br>Snø den neste halvtimen. |

### Duggfall

| Situasjon | Bokmål | Inntrøndersk |
|---|---|---|
| Sikkert, i morgen | **Det blir Duggfall! på Klinga i morgen.**<br>Duggfall ved 8° onsdag kl. 05. | **D bli Doggfall! på Klinga i mårrå.**<br>Doggfall ved 8° onsda'n kl. 05. |
| Usikkert, i natt | **Det kan bli Duggfall! på Klinga i natt.**<br>Fare for dugg kl. 23. | **D kan bli Doggfall! på Klinga i natt.**<br>Fare for doggfall kl. 23. |
| Pågår nå | **Det er duggfall!**<br>Duggpunktet er nær lufttemperaturen. | **D e doggfall!**<br>Doggpunktet e nær lufttemperaturen. |

### Frost

| Situasjon | Bokmål | Inntrøndersk |
|---|---|---|
| Sikkert, i natt | **Det blir Frost! på Klinga i natt.**<br>Frost kl. 04 — gjennom natta. | **D bli Frost! på Klinga i natt.**<br>Frost kl. 04 — gjennom natta. |
| Marginbasert | **Det kan bli Frost! på Klinga i natt.**<br>Fare for frost kl. 04. | **D kan bli Frost! på Klinga i natt.**<br>Fare for frost kl. 04. |
| Pågår nå | **Det er frost!**<br>Lokalt anslag er under frostgrensen. | **D e frost!**<br>Lokalt anslag e under frostgrensa. |

### Vindkast

| Situasjon | Bokmål | Inntrøndersk |
|---|---|---|
| Frisk bris, i morgen | **Det blir Vind! bortpå Klinga i morgen.**<br>Frisk bris mandag kl. 10 — i tre timer. | **D bli Vind! bortpå Klinga i mårrå.**<br>Frisk bris manda'n kl. 10 — i tre tima. |
| Sterkt, til helga | **Det blir Vind! oppå Hornburu til helga.**<br>Stormkast lørdag kl. 14 — i to timer. | **D bli Vind! oppå Hornburu te helga.**<br>Stormkasta lørda'n kl. 14 — i to tima. |
| Pågår nå | **Det blåser!**<br>Vindkast opptil 14 m/s. | **D blæs!**<br>Vindkasta oppte 14 m/s. |

### Sol

| Situasjon | Bokmål | Inntrøndersk |
|---|---|---|
| Sikkert, i morgen | **Det blir Sol! inni Hornburu i morgen.**<br>Sol fredag kl. 12 — i sju timer. | **D bli Sol! inni Hornburu i mårrå.**<br>Sol freda'n kl. 12 — i sju tima. |
| Usikkert | **Det kan bli Sol! oppi Selbu til helga.**<br>Solgløtt lørdag kl. 11 — i fire timer. | **D kan bli Sol! oppi Selbu te helga.**<br>Solgløtt lørda'n kl. 11 — i fire tima. |
| Pågår nå | **Det er sol!**<br>Lite skydekke akkurat nå. | **D e sol!**<br>Lite skydekke no. |

### Temperatur

| Situasjon | Bokmål | Inntrøndersk |
|---|---|---|
| Under grense, i natt | **Det blir Under 10°! nerri Namsos i natt.**<br>Under 10° kl. 02 — gjennom natta. | **D bli Under 10°! nerri Namsos i natt.**<br>Under 10° kl. 02 — gjennom natta. |
| Over grense, i morgen | **Det blir Over 20°! på Klinga i morgen.**<br>Over 20° onsdag kl. 14 — i tre timer. | **D bli Over 20°! på Klinga i mårrå.**<br>Over 20° onsda'n kl. 14 — i tre tima. |
| Pågår nå | **Det er under 10°!** | **D e under 10°!** |

## Korte flater

Push bruker de to linjene over. Watch og CarPlay komprimerer, men skal bruke
samme værord og samme tidsbetydning.

| Flate | Bokmål | Inntrøndersk |
|---|---|---|
| Apple Watch — rund komplikasjon | `Regn! · 23 m` | `Regn! · 23 m` |
| Apple Watch — inline-komplikasjon | `Regn! 23m` | `Regn! 23m` |
| Apple Watch — stor komplikasjon | `Klinga 8°`<br>`Regn! om 23 m` | `Klinga 8°`<br>`Regn! om 23 m` |
| CarPlay-widget | `D bli Vær! på Klinga`<br>`Regn om 23 minutter.`<br>`Duggfall i natt.` | `D bli Vær! på Klinga`<br>`Regn om 23 minutt.`<br>`Doggfall i natt.` |
| Rent appvarsel | `D bli Vær!`<br>`Appen må startes for å aktivere varsler.` | `D bli Vær!`<br>`Appen må startes for å aktivere varsler.` |

## Åpne valg før kobling til appen

1. Er «Regnbyga», «Snøbyga», «Nånn snøfnugg» og «Stormkasta» riktig nivå av
   inntrøndersk, eller skal de være mer nøytrale?
2. Skal bokmål ha «Det blir», mens inntrøndersk har «D bli» konsekvent, slik
   dette utkastet foreslår?
3. Skal «Fare for doggfall» heller være «Mulig doggfall» i alle usikre
   tilfeller?
4. Skal vind fortsatt hete «Vind!» i første linje, eller «Vindkast!» når
   grunnlaget alltid er kast?

Når dette er gått gjennom, kan de vedtatte formuleringene kobles til
`Sprak.json` og brukes likt i push, Varsler-siden, Watch og CarPlay.
