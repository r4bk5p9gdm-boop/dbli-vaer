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
4. **AUTO · KLAR** — Pansre Live Activity-livsløpet: valg av neste hendelse,
   foreldelse, avslutning, gjenåpning og regresjonstester.
5. **AUTO · KLAR** — Pansre synkronisering med Apple Watch og widgets ved
   manglende nett, gammel prognose og raske stedsskifter.
6. **AUTO · KLAR** — Bygg faste testdata for Yr/Nå-varsel og test prioritering
   av regn, snø, sludd, dugg, sol, vind og temperaturgrenser.
7. **AUTO · KLAR** — Kontroller datalagring og migrering fra eldre versjoner,
   inkludert regler, steder, språkvalg og globale innstillinger.
8. **AUTO · KLAR** — Mål og forbedre unødvendig arbeid, nettbruk og samtidighet
   uten å endre synlig oppførsel.
9. **AUTO · KLAR** — Samkjør tekst, ikoner og begreper mellom app, push,
   widget, Live Activity og Apple Watch gjennom delte modeller og tester.
10. **AUTO · KLAR** — Utvid før-lanseringstesten med kritiske ende-til-ende-
   scenarioer og dokumenter en repeterbar lanseringssjekk.

## Forslag som venter på godkjenning

Ingen.

## Ferdig

- 2026-09-10: Pansret varslingsmotoren slik at en hendelse med utløpt
  varslingstid ikke skjuler neste hendelse, regn-duplikater vurderes etter
  hendelsestid, dugg dempes også etter snø, varsel-ID-er er entydige per sted
  og iOS-grensen på 64 varsler håndteres deterministisk. 40 av 40 tester
  bestod.
- 2026-09-10: Fjernet Logg som egen bunnmeny og den dupliserte visningen av
  planlagte varsler. Siste status og ren oppdateringslogg ligger nå i Varselkø.
  36 av 36 tester bestod.
- 2026-09-10: Git-grunnlinje og aktiv vedlikeholdsarbeider med fire timers
  vurderingsrytme. Hele testpakken besto (36 av 36).
