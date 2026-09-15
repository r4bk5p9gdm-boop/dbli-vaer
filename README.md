# D bli Vær! – værvarsler fra Yr med avanserte pushinnstillinger

SwiftUI-app for iPhone (iOS 17+). Henter prognose fra MET/Yr sitt Locationforecast-API
og planlegger lokale varsler på telefonen for regn, frost, snø, vind, duggpunkt og skyfritt.

## Slik kjører du den

Åpne `VarselApp.xcodeproj`, velg ditt team under **Signing & Capabilities**, koble til en iPhone og trykk Run. Prosjektet bruker bundle-ID `no.mathias.VarselApp`; endre denne i Xcode dersom den ikke er unik for utviklerkontoen din.

Hvis du endrer `project.yml`, kan prosjektfilen bygges på nytt med [XcodeGen](https://github.com/yonaskolb/XcodeGen) ved å kjøre `xcodegen` i denne mappen.

## Funksjoner

- 48-timers prognose fra MET/Yr for flere steder
- Stedssøk og valg av nåværende posisjon
- Egne regler per sted for regn, frost, snø, vind, duggpunkt og skyfritt
- Eget klokkeslettområde per regel, forvarsel, ukedager og stille tid
- Ett varsel per sammenhengende værhendelse som standard, med valgfrie ekstra påminnelser
- «Aktuelt»-visning med formuleringer som «Skyfritt i 6 timer nå» og «Regn om 3 timers tid»
- Widget i liten og mellomstor størrelse for valgt sted
- Lokale varsler som planlegges på nytt ved prognoseoppdatering
- Bakgrunnsoppdatering og logg over gjeldende varslingsplan

## Viktig om Yr/MET
API-et krever en identifiserende `User-Agent`. Appen sender appnavn, versjon og bundle-ID. Før offentlig distribusjon bør du i tillegg legge inn kontaktinformasjon i `YrService.userAgent`, i tråd med METs vilkår.

## Begrensninger
- iOS bestemmer selv hvor ofte bakgrunnsoppdateringen kjører (typisk noen ganger i timen når appen brukes jevnlig).
  Varsler planlegges på nytt hver gang prognosen hentes. For helt presis timing trengs en egen server med push.
- Prognosen dekker de neste 48 timene.

## Kontinuerlig vedlikehold

Den prioriterte og nummererte arbeidskøen ligger i `VEDLIKEHOLD.md`. Oppgaver
merket `BRUKER` går foran automatisk valgt vedlikehold, og større UI-endringer
skal godkjennes før de gjennomføres.

## Widget og signering

Appen og widgeten deler prognosen gjennom App Group `group.no.mathias.dblivaer`. Velg samme utviklerteam for begge targets i Xcode. Hvis du endrer bundle-ID eller App Group, må gruppen også oppdateres i begge entitlement-filene og i `SharedWidgetData.swift`.

## Ressurslett byggkontroll uten simulator

Kjør `./verify_targets.sh` fra prosjektmappen før en større endring. Skriptet
bygger iPhone-, iPhone-widget-, Watch- og Watch-widget-målene mot generiske
enheter, bruker en delt avledet-data-mappe og starter ingen simulator. Det
stopper hvis et annet `xcodebuild` allerede kjører eller en simulator er
startet, slik at vedlikehold og Claude ikke konkurrerer om ressurser.
