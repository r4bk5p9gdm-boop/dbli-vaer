# Varseltekster — styringsdokument

Dette er språkfasiten for **D bli Vær!**. Hver rad er en formulering som kan
rettes her, uten å lete i Swift-koden. Bokmål og inntrøndersk er aktive språk.
Engelsk venter til den norske teksten er godkjent.

## Slik redigeres dokumentet

- Tekst i {krøllparenteser} er data appen setter inn, ikke visningsord.
- Første linje er handlingssetningen. Andre linje forklarer styrke,
  klokkeslett og eventuelt varighet.
- Én tankestrek (—) skiller tidspunkt fra varighet.
- Skriv direkte i riktig språkcelle. En stjerne er ikke nødvendig. En
  kommentar kan eventuelt stå på neste linje som sitat med >.

## Felles maler

### Push — første linje

| Situasjon | Bokmål | Inntrøndersk |
| --- | --- | --- |
| Sikkert | **D bli {Værtype}! {preposisjon} {sted} {tid}.** | **D bli {Værtype}! {preposisjon} {sted} {tid}.** |
| Usikkert | **Det kan bli {Værtype}! {preposisjon} {sted} {tid}.** | **D kan bli {Værtype}! {preposisjon} {sted} {tid}.** |
| Pågår nå | Se værtypens egen nå-tekst nedenfor. | Se værtypens egen nå-tekst nedenfor. |

### Værtypenavn og nå-tekst

Første linje bruker stor forbokstav i værtypen. Stedets egen preposisjon
beholdes, som på Klinga, nerri Namsos eller oppi Hornburu.

| Type | Bokmål i første linje | Inntrøndersk i første linje | Nå-tekst bokmål | Nå-tekst inntrøndersk |
| --- | --- | --- | --- | --- |
| Regn | Regn | Regn | D e Regn! | D e Regn! |
| Snø | Snø | Snø | Det Snør! | Det Snør! |
| Vind | Vindkast | Vindkast | Det blåser! | D blæs! |
| Dugg | Duggfall | Doggfall | Det er duggfall! | D Dogge! |
| Frost | Frost | Frost | Det er frost! | D e Frost! |
| Sol | Sol | Sol | Det er sol! | D e Sol! |
| Temperatur | Under {grense}° / Over {grense}° | Under {grense}° / Over {grense}° | Det er under {grense}°! | D e Under {grense}°! |

Temperatur er et unntak fra det generelle værtypenavnet: appen skal aldri
skrive «D bli Temperatur!». Den må alltid si hva som skjer, for eksempel
**D bli Under 10°!** eller **D bli Over 20°!**. På bokmål brukes små bokstaver
i nåsetningen: **Det er under 10°!** / **Det er over 20°!**.

### Tid i første linje

| Når hendelsen starter | Bokmål | Inntrøndersk | Merknad |
| --- | --- | --- | --- |
| 0–59 minutter | om et kvarter / om en halvtime / om 45 minutter | om et kvarter / om en halvtime / om tre kvarter | Naturlig avrundet uttrykk. |
| 1–23 timer | om 2 timer | om 2 tima | Bare når kveld/natt ikke passer bedre. |
| Senere i dag | i dag / i kveld | i dag / i kveld | I kveld fra kl. 15. |
| Kl. 23–06 neste kalenderdag | i natt | i natt | Aldri «i morgen kl. 02». |
| Neste dag fra kl. 06 | i morgen | i mårrå | Klokkeslettet kommer på andre linje. |
| Overmorgen | på {ukedag} | på {ukedag-trønder} | På søndag / på sønda'n. |
| Helgeregel | til helga | te helga | Kun for aktiv helgeregel. |

### Andre linje i push

| Regel | Bokmål | Inntrøndersk |
| --- | --- | --- |
| Samme dag eller natt | **{Værbeskrivelse} kl. {HH} — {varighet}.** | **{Værbeskrivelse} kl. {HH} — {varighet}.** |
| I morgen, ukedag eller helg | **{Værbeskrivelse} {ukedag} kl. {HH} — {varighet}.** | **{Værbeskrivelse} {ukedag-trønder} kl. {HH} — {varighet}.** |
| Kortere enn én time | Varighet er alltid med, avrundet til 15, 30 eller 45 min. | Varighet er alltid med, avrundet til 15, 30 eller 45 min. |
| 1–4 timer | i 2 timer | i 2 tima |
| Mesteparten av natta | hele natta | heile natta |
| Mesteparten av dagen | store deler av dagen | store dela av da'n |

Andre linje gjentar ikke i morgen, i natt eller til helga fra første linje.
Den går rett på dag og klokkeslett når dette gir ny informasjon.

### Hjem — rullerende varsel

| Situasjon | Første linje | Andre linje |
| --- | --- | --- |
| Framtidig | **D bli {Værtype}! {kort tid}.** | {varighet} {værbeskrivelse} fra kl. {HH}. |
| Usikkert | **D kan bli {Værtype}! {kort tid}.** | Bare hvis den tilfører noe nytt. |
| Pågår nå | **{Nå-tekst}!** | {værbeskrivelse} i {varighet} til. |

Eksempel: **D bli Regn! om 2 tima.** / **4 tima småregn fra kl. 14.**
Nåstatus bruker aldri «fra kl.»: **D blæs!** / **Fresk bris i 2 tima til.**
Varighet er alltid med: under én time avrundes til 15, 30 eller 45 min;
deretter brukes hele timer. Eksempel: **D bli Regn! om en halvtime.** /
**30 min småregn fra kl. 14.**

Hvis en NÅ-status bare er prognoseusikker, kan den ikke påstå at været skjer
allerede. Da brukes den usikre formen, som **Det kan bli Regn!** / **D kan bli
Regn!**, i stedet for **D e Regn!**.

Sol og solgløtt er bare gyldige mellom lokal soloppgang og solnedgang. Etter
solnedgang viser NÅ-kortet **sola er nede** med måneikon, solraden får ingen
gul markering, og det planlegges ikke solvarsel eller solpush.

For en lang, usikker regnperiode brukes en roligere, ikke-dupliserende detalj:
**D kan bli Regn! i mårrå, kl. 09.** ↳ **Oppte 10 tima regnbyga på tirsda'n.**
Førstelinjen har dermed tidskategori og klokkeslett; detaljlinjen har varighet
og dag, men gjentar ikke klokkeslettet eller ordet «mulig».

### Apple Watch og CarPlay-widget

Korte flater bruker samme prioriterte hendelsesliste og rullerer ikke selv.

| Flate | Innhold |
| --- | --- |
| Rund komplikasjon | Værtype + kort nedtelling, som Regn! · 23 m. |
| Inline-komplikasjon | Regn! 23m. |
| Stor/rektangulær Watch-komplikasjon | Sted og temperatur, deretter inntil tre neste ulike hendelser. Ingen «Neste 12 timer». |
| CarPlay-widget | Samme sted som Watch, med inntil tre neste ulike hendelser. |

23 m og 2 t er nedtelling til start. «I 4 timer» / «i 4 tima» er varighet og
hører ikke hjemme i sirkelen.

---

# Regn

### Styringstabell

| Mengde / situasjon | Bokmål | Inntrøndersk |
| --- | --- | --- |
| Svært lite | Yr | Yr |
| Lite | Litt regn | Småregn |
| Vanlig | Regn | Regn |
| Mye | Kraftig regn | Striskur |
| Byger i samme periode | Spredte regnbyger | Regnbyga |

Regnbyger brukes når det kommer og går, men uten et tørt opphold på minst én
time. Varigheten er hele bygeperioden, ikke hvert enkelt regnskyll. Et opphold
på én time eller mer starter en ny nedbørhendelse.

## Push-varsel

| Situasjon | Bokmål | Inntrøndersk |
| --- | --- | --- |
| Sikkert, neste dag | **D bli Regn! nerri Namsos i morgen.** ↳ Litt regn mandag kl. 06 — i to timer. | **D bli Regn! nerri Namsos i mårrå.** ↳ Småregn manda'n kl. 06 — i to tima. |
| Usikkert, nært | **Det kan bli Regn! på Klinga om en halvtime.** ↳ Yr kl. 14 — i 30 min. | **D kan bli Regn! på Klinga om en halvtime.** ↳ Yr kl. 14 — i 30 min. |
| Kraftig i natt | **D bli Regn! oppi Hornburu i natt.** ↳ Kraftig regn kl. 02 — hele natta. | **D bli Regn! oppi Hornburu i natt.** ↳ Striskur kl. 02 — heile natta. |

## Hjem — rullerende varsel

| Situasjon | Bokmål | Inntrøndersk |
| --- | --- | --- |
| Framtidig | **D bli Regn! om 2 timer.** ↳ 4 timer med litt regn fra kl. 14. | **D bli Regn! om 2 tima.** ↳ 4 tima med småregn fra kl. 14. |
| Nært | **D bli Regn! om en halvtime.** ↳ 30 min litt regn fra kl. 14. | **D bli Regn! om en halvtime.** ↳ 30 min småregn fra kl. 14. |
| Pågår nå | **D e Regn!** ↳ Litt regn i 45 min til. | **D e Regn!** ↳ Småregn i 45 min til. |

## Watch og CarPlay-widget

| Situasjon | Språk | Rund | Inline | Stor Watch / CarPlay-rad |
| --- | --- | --- | --- | --- |
| Neste hendelse | Bokmål | Regn! · 23 m | Regn! 23m | Regn! 23m |
| Neste hendelse | Inntrøndersk | Regn! · 23 m | Regn! 23m | Regn! 23m |

---

# Snø

### Styringstabell

| Mengde / situasjon | Bokmål | Inntrøndersk |
| --- | --- | --- |
| Svært lett | Snøfnugg | Snøfnugg |
| Lett | Lett snøfall | Litt snø |
| Vanlig | Snøfall | Snøfall |
| Mye | Kraftig snøfall | Mye snø |
| Byger | Snøbyger | Snøbyga |

## Push-varsel

| Situasjon | Bokmål | Inntrøndersk |
| --- | --- | --- |
| Sikkert, i natt | **D bli Snø! oppi Selbu i natt.** ↳ Lett snøfall kl. 02 — hele natta. | **D bli Snø! oppi Selbu i natt.** ↳ Litt snø kl. 02 — heile natta. |
| Usikkert, neste dag | **Det kan bli Snø! på Klinga i morgen.** ↳ Snøfnugg tirsdag kl. 07 — i en time. | **D kan bli Snø! på Klinga i mårrå.** ↳ Snøfnugg tirsda'n kl. 07 — i en time. |

## Hjem — rullerende varsel

| Situasjon | Bokmål | Inntrøndersk |
| --- | --- | --- |
| Framtidig | **D bli Snø! om 3 timer.** ↳ 2 timer lett snøfall fra kl. 17. | **D bli Snø! om 3 tima.** ↳ 2 tima litt snø fra kl. 17. |
| Pågår nå | **Det Snør!** ↳ Snøfall i 2 timer til. | **Det Snør!** ↳ Snøfall i 2 tima til. |

## Watch og CarPlay-widget

| Situasjon | Språk | Rund | Inline | Stor Watch / CarPlay-rad |
| --- | --- | --- | --- | --- |
| Neste hendelse | Bokmål | Snø! · 2 t | Snø! 2t | Snø! 2t |
| Neste hendelse | Inntrøndersk | Snø! · 2 t | Snø! 2t | Snø! 2t |

---

# Vindkast

### Styringstabell — forenklet Beaufort

| Vindkast m/s | Bokmål | Inntrøndersk |
| --- | --- | --- |
| 0 | Still | Blikkstilla |
| 1 | Flau vind | Liten gufs |
| 2–3 | Svak vind | Trekk |
| 4–5 | Lett bris | Lett bris |
| 6–7 | Laber bris | Blæs freskt |
| 8–10 | Frisk bris | Fresk bris |
| 11–13 | Liten kuling | Liten kuling |
| 14–17 | Stiv kuling | Stiv kuling |
| 18–20 | Sterk kuling | Sterk kuling |
| 21–24 | Liten storm | Blæs hatta og høy |
| 25–28 | Full storm | Blæs opp t uvær |
| 29–32 | Sterk storm | Sterk storm |
| 33+ | Orkan | Orkan |

Vindvarsel følger **vindkast**, ikke middelvind. Værdata kan fortsatt vise
begge slik Yr gjør.

## Push-varsel

| Situasjon | Bokmål | Inntrøndersk |
| --- | --- | --- |
| Sikkert, neste dag | **D bli Vindkast! på Klinga i morgen.** ↳ Frisk bris mandag kl. 14 — i tre timer. | **D bli Vindkast! på Klinga i mårrå.** ↳ Fresk bris manda'n kl. 14 — i tre tima. |
| Usikkert, helg | **Det kan bli Vindkast! oppi Selbu til helga.** ↳ Liten kuling søndag kl. 14 — i to timer. | **D kan bli Vindkast! oppi Selbu te helga.** ↳ Liten kuling sønda'n kl. 14 — i to tima. |

## Hjem — rullerende varsel

| Situasjon | Bokmål | Inntrøndersk |
| --- | --- | --- |
| Framtidig | **D bli Vindkast! om 3 timer.** ↳ Frisk bris i fire timer. | **D bli Vindkast! om 3 tima.** ↳ Fresk bris i fire tima. |
| Pågår nå | **Det blåser!** ↳ Frisk bris i 2 timer til. | **D blæs!** ↳ Fresk bris i 2 tima til. |

## Watch og CarPlay-widget

| Situasjon | Språk | Rund | Inline | Stor Watch / CarPlay-rad |
| --- | --- | --- | --- | --- |
| Neste hendelse | Bokmål | Vind! · 45 m | Vind! 45m | Vind! 45m |
| Neste hendelse | Inntrøndersk | Vind! · 45 m | Vind! 45m | Vind! 45m |

---

# Duggfall

### Styringstabell

| Situasjon | Bokmål | Inntrøndersk |
| --- | --- | --- |
| Sikkert | Duggfall | Doggfall |
| Usikkert | Mulig duggfall | Mulig doggfall |
| Pågår nå | Det er duggfall | D Dogge |

I pushvarsler kan beregnet lokal temperatur forklare grunnlaget. I Hjem, Watch
og CarPlay brukes ikke duggpunktstall: varighet og starttid er nyttigere.
Den korte, sikre inntrønderske overskriften bruker **Dogg!**; usikker push
beholder det forklarende **mulig doggfall**.

## Push-varsel

| Situasjon | Bokmål | Inntrøndersk |
| --- | --- | --- |
| Sikkert, neste dag | **D bli Duggfall! på Klinga i morgen.** ↳ Duggfall ved 8° tirsdag kl. 05 — i tre timer. | **D bli Dogg! på Klinga i mårrå.** ↳ Doggfall ved 8° tirsda'n kl. 05 — i tre tima. |
| Usikkert, natt | **Det kan bli Duggfall! på Klinga i natt.** ↳ Mulig duggfall ved 7° kl. 02 — i tre timer. | **D kan bli Doggfall! på Klinga i natt.** ↳ Mulig doggfall ved 7° kl. 02 — i tre tima. |

## Hjem — rullerende varsel

| Situasjon | Bokmål | Inntrøndersk |
| --- | --- | --- |
| Framtidig | **D bli Duggfall! om 3 timer.** ↳ Duggfall i 3 timer fra kl. 05. | **D bli Dogg! om 3 tima.** ↳ Doggfall i 3 tima fra kl. 05. |
| Pågår nå | **Det er Duggfall!** ↳ Duggpunkt ved 7°C. | **D Dogge!** ↳ Doggpunkt ved 7°C. |

## Watch og CarPlay-widget

| Situasjon | Språk | Rund | Inline | Stor Watch / CarPlay-rad |
| --- | --- | --- | --- | --- |
| Neste hendelse | Bokmål | Dugg! · 45 m | Dugg! 45m | Dugg! 45m |
| Neste hendelse | Inntrøndersk | Dogg! · 45 m | Dogg! 45m | Dogg! 45m |

---

# Frost

### Styringstabell

| Situasjon | Bokmål | Inntrøndersk |
| --- | --- | --- |
| Sikkert, lokal temperatur ved/under 0° | Frost | Frost |
| Marginbasert, over 0° | Fare for frost | Fare for frost |
| Pågår nå | Det er frost | D e Frost |

Hvit markering i temperatur-raden betyr faktisk 0° eller kaldere. Blå
frostmarkør betyr marginbasert frostfare over 0°.

## Push-varsel

| Situasjon | Bokmål | Inntrøndersk |
| --- | --- | --- |
| Sikkert | **D bli Frost! på Klinga i natt.** ↳ Frost ved −1° kl. 03 — i fire timer. | **D bli Frost! på Klinga i natt.** ↳ Frost ved −1° kl. 03 — i fire tima. |
| Marginbasert | **Det kan bli Frost! på Klinga i morgen.** ↳ Fare for frost ved 2° tirsdag kl. 05 — i to timer. | **D kan bli Frost! på Klinga i mårrå.** ↳ Fare for frost ved 2° tirsda'n kl. 05 — i to tima. |

## Hjem — rullerende varsel

| Situasjon | Bokmål | Inntrøndersk |
| --- | --- | --- |
| Framtidig | **D bli Frost! i natt.** ↳ Frost ved −1° i fire timer fra kl. 03. | **D bli Frost! i natt.** ↳ Frost ved −1° i fire tima fra kl. 03. |
| Pågår nå, sikkert | **Det er frost!** ↳ Frost i to timer til. | **D e Frost!** ↳ Frost i 2 tima til. |
| Pågår nå, marginbasert | **Det kan bli Frost!** ↳ Fare for frost i to timer til. | **D kan bli Frost!** ↳ Fare for frost i 2 tima til. |

## Watch og CarPlay-widget

| Situasjon | Språk | Rund | Inline | Stor Watch / CarPlay-rad |
| --- | --- | --- | --- | --- |
| Neste hendelse | Bokmål | Frost! · 2 t | Frost! 2t | Frost! 2t |
| Neste hendelse | Inntrøndersk | Frost! · 2 t | Frost! 2t | Frost! 2t |

---

# Sol

### Styringstabell

| Situasjon | Bokmål | Inntrøndersk |
| --- | --- | --- |
| Klart | Sol | Sol |
| Sol bak skyer | Solgløtt | Solgløtt |

Sol er en valgt regel, ikke standard push. Den vises heller ikke etter lokal
solnedgang. «Sol om 4 timer» beskriver start; «sol i 4 timer» beskriver
varighet.

## Push-varsel

| Situasjon | Bokmål | Inntrøndersk |
| --- | --- | --- |
| Sikkert | **D bli Sol! i Bergen i morgen.** ↳ Sol fredag kl. 12 — i sju timer. | **D bli Sol! i Bergen i mårrå.** ↳ Sol fredag kl. 12 — i sju tima. |
| Usikkert | **Det kan bli Sol! på Klinga i morgen.** ↳ Solgløtt tirsdag kl. 10 — i to timer. | **D kan bli Sol! på Klinga i mårrå.** ↳ Solgløtt tirsda'n kl. 10 — i to tima. |

## Hjem — rullerende varsel

| Situasjon | Bokmål | Inntrøndersk |
| --- | --- | --- |
| Framtidig | **D bli Sol! om 4 timer.** ↳ Sol i 7 timer fra kl. 12. | **D bli Sol! om 4 tima.** ↳ Sol i 7 tima fra kl. 12. |
| Pågår nå | **Det er sol!** ↳ Sol i 2 timer til. | **D e Sol!** ↳ Sol i 2 tima til. |

## Watch og CarPlay-widget

| Situasjon | Språk | Rund | Inline | Stor Watch / CarPlay-rad |
| --- | --- | --- | --- | --- |
| Neste hendelse | Bokmål | Sol! · 4 t | Sol! 4t | Sol! 4t |
| Neste hendelse | Inntrøndersk | Sol! · 4 t | Sol! 4t | Sol! 4t |

---

# Temperatur

Temperaturvarsel kan ha både under- og overgrense. Kald temperatur bruker blå
markering og varm temperatur rød-oransje markering på Hjem.

## Push-varsel

| Situasjon | Bokmål | Inntrøndersk |
| --- | --- | --- |
| Undergrense | **D bli Under 10°! på Klinga i morgen.** ↳ 8° mandag kl. 06 — i tre timer. | **D bli Under 10°! på Klinga i mårrå.** ↳ 8° manda'n kl. 06 — i tre tima. |
| Overgrense | **D bli Over 20°! på Klinga i morgen.** ↳ 22° mandag kl. 14 — i fire timer. | **D bli Over 20°! på Klinga i mårrå.** ↳ 22° manda'n kl. 14 — i fire tima. |

## Hjem — rullerende varsel

| Situasjon | Bokmål | Inntrøndersk |
| --- | --- | --- |
| Undergrense, framtidig | **D bli Under 10°! om 2 timer.** ↳ Lokalt anslag 8° i tre timer fra kl. 06. | **D bli Under 10°! om 2 tima.** ↳ Lokalt anslag 8° i tre tima fra kl. 06. |
| Overgrense, framtidig | **D bli Over 20°! om 3 timer.** ↳ Lokalt anslag 22° i fire timer fra kl. 14. | **D bli Over 20°! om 3 tima.** ↳ Lokalt anslag 22° i fire tima fra kl. 14. |
| Pågår nå, undergrense | **Det er under 10°!** ↳ Minimumstemp i dag blir 5°C. | **D e Under 10°!** ↳ Minimumstemp i dag blir 5°C. |
| Pågår nå, overgrense | **Det er over 20°!** ↳ Maksimumstemp i dag blir 22°C. | **D e Over 20°!** ↳ Maksimumstemp i dag blir 22°C. |

## Watch og CarPlay-widget

| Situasjon | Språk | Rund | Inline | Stor Watch / CarPlay-rad |
| --- | --- | --- | --- | --- |
| Neste hendelse, under | Bokmål | <10° · 2 t | <10° 2t | <10° 2t |
| Neste hendelse, under | Inntrøndersk | <10° · 2 t | <10° 2t | <10° 2t |
| Neste hendelse, over | Bokmål | >20° · 2 t | >20° 2t | >20° 2t |
| Neste hendelse, over | Inntrøndersk | >20° · 2 t | >20° 2t | >20° 2t |

---

## Opphold og nåkort

Opphold er status i nåkortet, ikke et eget pushvarsel. Det konkurrerer ikke
med varsler om regn, snø, vind, dugg, frost, sol eller temperatur.

| Situasjon | Bokmål | Inntrøndersk |
| --- | --- | --- |
| Nåkort | Opphold | Opphold |
| Forklaring | Ingen nedbør neste time. | Ingen nedbør neste time. |

## Kvalitetssjekk

1. Samme hendelse bruker samme værord i push, Hjem, Watch og CarPlay.
2. Push har sted og tidskategori på første linje. Hjem har kort tid i første
   linje og detalj uten gjentakelse på andre.
3. Duggtemperatur kan forklare et pushvarsel, men vises ikke i rullerende
   duggvarsel eller på korte flater.
4. «Fra kl.» brukes bare for framtidige Hjem-detaljer. «Til» brukes bare når
   noe faktisk pågår nå.
5. Nærmeste hendelse prioriteres på Watch og CarPlay; korte flater viser maks
   tre ulike værtyper.
6. Temperatur bruker alltid under- eller overgrense i tekst og symbol. Aldri
   det generelle ordet «Temperatur» som selve varseltypen.
7. En usikker NÅ-prognose bruker «kan bli», aldri en påstand om at været pågår.
8. Rullerende vind gjentar ikke startklokkeslettet under en overskrift som
   allerede sier når det blåser; detaljen er bare styrke og varighet.

## Koblingsstatus

Dokumentet er språkfasit. Push og rullerende Hjem-varsel bruker nå samme
retning for temperatur under/over, samme tidskategori i førstelinjen og
varighet i andrelinjen — også når perioden bare er én time. Rullerende Hjem
har en testbar generator for alle værtyper, sikker/usikker NÅ-status og begge
temperaturretninger. Watch og CarPlay bruker den samme statuslisten og korte
etiketter per type.

Regresjonsmatrisen ligger i `PlannerTests`: alle værtyper testes i bokmål og
inntrøndersk, med sikker/usikker push og under/over for temperatur. Full
testkjøring er foreløpig sperret av eldre, urelaterte Swift 6-/MainActor-feil i
testmålet; iPhone-, Watch- og widgetmålene bygger.

> Språkfunn til gjennomgang: «D bli» er appens bevisste, korte stil også i
> bokmålskolonnen. Det er ikke vanlig bokmål; hvis bokmål skal være strengt,
> bør førsteordet i alle bokmålseksempler og `push.title` endres til «Det blir».
