# Vedlikehold av D bli Vær!

Dette dokumentet er den nummererte arbeidskøen for den kontinuerlige
vedlikeholdsarbeideren. Nye oppgaver fra Mathias legges øverst blant åpne
oppgaver og merkes `BRUKER`. De går alltid foran oppgaver merket `AUTO`.

## Arbeidsregler

- Ta én avgrenset oppgave om gangen og revurder prioriteringen før hver økt.
- Prioriter korrekt værlogikk, robuste varsler, datalagring, bakgrunnskjøring,
  Watch-synkronisering, ytelse og regresjonstester før nye funksjoner.
- Små, reversible forbedringer kan gjennomføres selvstendig.
- Større endringer i navigasjon, oppbygning eller visuelt uttrykk skal bare
  beskrives som forslag og merkes `KREVER GODKJENNING`.
- Bevar brukerens ulagrede og urelaterte endringer. Ikke skriv om Git-historikk.
- Kjør relevante tester og bygg for berørte mål. Ikke commit en kjent feilende
  endring.
- Lag én fokusert commit per ferdige oppgave. Oppdater denne listen i samme
  commit og rapporter commit-id, kontrollene som ble kjørt og neste prioritet.
- Ikke publiser appen, endre signering eller kontakte eksterne tjenester uten
  uttrykkelig beskjed.

## Nummerert kø

1. **BRUKER · FERDIG** — Etabler kontinuerlig vedlikehold, Git-grunnlinje,
   prioriteringsregler og rapportering. Grunnlinje: `a991a0f`, 36 tester bestått.
2. **BRUKER · FERDIG** — Fjern duplikatet mellom menyene Varselkø og Logg,
   men behold oppdateringshistorikken lett tilgjengelig.
3. **AUTO · FERDIG** — Pansre varslingsmotoren: tidsvinduer, tidssoner,
   duplikatdemping, nedbør–dugg-konflikter og grensen for lokale varsler.
4. **BRUKER · FERDIG** — Sett vedlikeholdsarbeideren i kontinuerlig
   femminuttersrytme og bruk tilgjengelige resetter bare når en bruksgrense
   ellers stopper arbeidet.
5. **AUTO · FERDIG** — Pansre Live Activity-livsløpet: valg av neste hendelse,
   foreldelse, avslutning, gjenåpning og regresjonstester.
6. **AUTO · FERDIG** — Pansre synkronisering med Apple Watch og widgets ved
   manglende nett, gammel prognose og raske stedsskifter.
7. **AUTO · FERDIG** — Bygg faste testdata for Yr/Nå-varsel og test prioritering
   av regn, snø, sludd, dugg, sol, vind og temperaturgrenser.
8. **AUTO · FERDIG** — Kontroller datalagring og migrering fra eldre versjoner,
   inkludert regler, steder, språkvalg og globale innstillinger.
9. **AUTO · FERDIG** — Mål og forbedre unødvendig arbeid, nettbruk og samtidighet
   uten å endre synlig oppførsel.
10. **BRUKER · VENTER PÅ ENHET** — Fullfør fysisk kontroll av Watch-appen og
   CarPlay-widgeten. Watch-målene er korrekt signert, men Apple Watch er ennå
   ikke synlig som utviklingsenhet i Xcode. Kontrollen fortsetter når
   Utviklermodus er slått på på klokka og den er paret med Xcode. CarPlay-
   widgeten kontrolleres etter at iPhone er låst opp, appen er startet én gang
   og widgeten er valgt under Innstillinger > Generelt > CarPlay. Denne
   ventende enhetskontrollen blokkerer ikke AUTO-oppgavene nedenfor.
11. **AUTO · KLAR** — Samkjør tekst, ikoner og begreper mellom app, push,
   widget, Live Activity og Apple Watch gjennom delte modeller og tester.
12. **AUTO · KLAR** — Utvid før-lanseringstesten med kritiske ende-til-ende-
   scenarioer og dokumenter en repeterbar lanseringssjekk.

## Forslag som venter på godkjenning

Ingen.

## Ferdig

- 2026-09-10: Reduserte nettbruk og samtidighetsbelastning. Bakgrunnsjobben
  henter nå bare valgt sted og steder med aktive pushregler; manuell oppdatering
  henter fortsatt alle steder. Flere navn på samme koordinat deler én Yr/Nå-
  henting, og antall samtidige steder er begrenset til fire for å unngå
  unødvendige forespørselsutbrudd. 52 av 52 tester bestod.
- 2026-09-10: Pansret lagring og oppgradering. Eldre oppsett uten logg og nye
  valg kan leses uten at stedene nullstilles. Gamle navn som «skyfritt», «snø»,
  «duggfall», «vindkast» og «inntrøndersk» migreres til dagens modeller. En
  ukjent regel eller et skadet sted forkaster bare den ene posten, og valgt
  sted repareres dersom referansen ikke lenger finnes. Eksportformatet tåler
  også manglende eldre metadata. 50 av 50 tester bestod.
- 2026-09-10: La inn faste Yr- og Nå-varseldata i testpakken. Overlappende
  1-times- og 6-timersperioder gir ikke lenger doble timer; den mest detaljerte
  1-timesverdien vinner. Våt Nå-radar gir presist starttidspunkt innen 90
  minutter, mens tørr radar ikke fjerner regn fra tabellvarslet. Grensene for
  regn, snø/sludd, dugg, sol, vind, frost og temperatur er låst med
  regresjonstester. 47 av 47 tester bestod.
- 2026-09-10: Pansret iPhone–Watch/widget-synkronisering. Nyeste sted og vær
  køes dersom WatchConnectivity ennå ikke er aktivert, siste overføring vinner
  ved raske stedsskifter, eldre overføringer avvises etter omstart, og sletting
  av siste sted rydder også gammel Watch/widget-status. Eldre appoverføringer
  kan fortsatt leses. 43 av 43 tester bestod.
- 2026-09-10: Pansret Live Activity-livsløpet. En startet aktivitet fortsetter
  gjennom de siste ti minuttene og mens været pågår, men avsluttes straks når
  regelen slås av, stedet ikke lenger kvalifiserer eller hendelsen avlyses eller
  flyttes ut av nærhorisonten. Kommende status bruker nå nærmeste værhendelse
  uavhengig av om pushens forvarseltid er passert. 42 av 42 tester bestod.
- 2026-09-10: Endret den aktive vedlikeholdsarbeideren fra fire timer til hvert
  femte minutt. Tre resetter er autorisert ved faktisk bruksstopp; de brukes
  ikke før en grense er nådd.
- 2026-09-10: Pansret varslingsmotoren slik at en hendelse med utløpt
  varslingstid ikke skjuler neste hendelse, regn-duplikater vurderes etter
  hendelsestid, dugg dempes også etter snø, varsel-ID-er er entydige per sted
  og iOS-grensen på 64 varsler håndteres deterministisk. 40 av 40 tester
  bestod.
- 2026-09-10: Fjernet Logg som egen bunnmeny og den dupliserte visningen av
  planlagte varsler. Siste status og ren oppdateringslogg ligger nå i Varselkø.
  36 av 36 tester bestod.
- 2026-09-10: Git-grunnlinje og aktiv vedlikeholdsarbeider med planlagt
  vurderingsrytme. Hele testpakken besto (36 av 36).
