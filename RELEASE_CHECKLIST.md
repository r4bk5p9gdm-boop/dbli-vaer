# Før lansering av D bli Vær!

Denne sjekklisten skal kjøres fra samme Git-commit som skal leveres. Stopp ved
første feil, rett feilen i en egen commit og start kontrollen på nytt.

## 1. Automatisk port

1. Kontroller at `git status --short` er tom.
2. Kjør hele testpakken på nyeste tilgjengelige iPhone-simulator:

   `xcodebuild test -project VarselApp.xcodeproj -scheme VarselApp -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`

3. Bekreft at testen bygger iPhone-appen, iPhone-widgeten, Live Activity,
   Watch-appen og Watch-widgeten, og at alle tester består.
4. Bygg samme commit for en fysisk iPhone med automatisk signering. Ikke endre
   team eller app-identifikator under kontrollen.

## 2. Kritisk værkjede

Test med faste testdata eller et sted der været kan sammenlignes med Yr:

- Yr-tabellen lastes, og Nå-varselet brukes bare innen 90 minutter.
- Regn i Nå-varselet gir presist starttidspunkt; et tørt Nå-varsel fjerner ikke
  regn fra tabellvarselet.
- Regn og snø skilles ved temperaturgrensen, og snømengde vises som anslått snø.
- Duggfall dempes under og i tre timer etter regn eller snø.
- Frostmargin endrer sannsynligheten for lokalt frostvarsel, men ikke den viste
  Yr-temperaturen.
- Kvelds-, morgen-, natt- og helgeregler bruker riktig dag, klokkeslett og norsk
  tidssone også over sommertidsskifte.
- Samme hendelse gir ikke doble varsler, og de nærmeste unike varslene beholdes
  når iOS-grensen på 64 nås.

## 3. Fysisk iPhone

- Oppgrader fra forrige installerte versjon og bekreft at steder, regler,
  preposisjoner, egne navn, språk, frostmargin og globale valg beholdes.
- Start appen, oppdater alle steder og sammenlign minst ett timevarsel med Yr.
- Send testvarsel på bokmål og inntrøndersk. Kontroller tittel, sted,
  preposisjon, klokkeslett, mengde/varighet og eventuell huskelapp.
- Trykk varselet og bekreft at appen åpner riktig sted.
- La et aktivert varsel komme innen én time, åpne appen og kontroller at Live
  Activity starter, oppdateres og avsluttes når hendelsen er over eller borte.
- Lås telefonen og kontroller widget i liten og mellomstor størrelse.
- La én bakgrunnsoppdatering kjøre og bekreft at valgt sted og steder med aktive
  pushregler oppdateres uten at alle passive steder hentes.

## 4. Apple Watch

- Slå på Utviklermodus på både iPhone og Apple Watch, og bekreft at klokka er
  synlig og paret i Xcode før installasjon.
- Installer fra samme bygg og bekreft at integriteten godtas.
- Endre valgt sted på iPhone og kontroller sted, temperatur, ikon, farge og
  aktuelle varsler i Watch-appen.
- Kontroller komplikasjonene for inline, sirkel, hjørne og rektangel samt Smart
  stabel. Åpning fra widget/komplikasjon skal vise Watch-appen.
- Test én oppdatering mens Watch er midlertidig frakoblet; nyeste sted skal
  komme fram når forbindelsen er tilbake.

## 5. CarPlay (iOS 26 eller nyere)

- Start iPhone-appen minst én gang etter installasjon.
- Velg D bli Vær! under Innstillinger > Generelt > CarPlay > bilen > Widgets.
- Koble til bilen på nytt og åpne widgetsiden til venstre for Dashboard.
- Bekreft énlinjet heading med valgt sted, riktig ikon/farge, første relevante
  varsel og neste varsel når det finnes.

## 6. Godkjenning

Noter commit-id, dato, iOS/watchOS-versjon, enhetene som ble brukt, antall
beståtte tester og eventuelle kjente begrensninger. Lanser først når alle porter
er grønne og arbeidskopien fortsatt er ren.
