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

1. **BRUKER · PÅGÅR** — Etabler kontinuerlig vedlikehold, Git-grunnlinje,
   prioriteringsregler og rapportering.
2. **AUTO · KLAR** — Pansre varslingsmotoren: tidsvinduer, tidssoner,
   duplikatdemping, nedbør–dugg-konflikter og grensen for lokale varsler.
3. **AUTO · KLAR** — Pansre Live Activity-livsløpet: valg av neste hendelse,
   foreldelse, avslutning, gjenåpning og regresjonstester.
4. **AUTO · KLAR** — Pansre synkronisering med Apple Watch og widgets ved
   manglende nett, gammel prognose og raske stedsskifter.
5. **AUTO · KLAR** — Bygg faste testdata for Yr/Nå-varsel og test prioritering
   av regn, snø, sludd, dugg, sol, vind og temperaturgrenser.
6. **AUTO · KLAR** — Kontroller datalagring og migrering fra eldre versjoner,
   inkludert regler, steder, språkvalg og globale innstillinger.
7. **AUTO · KLAR** — Mål og forbedre unødvendig arbeid, nettbruk og samtidighet
   uten å endre synlig oppførsel.
8. **AUTO · KLAR** — Samkjør tekst, ikoner og begreper mellom app, push,
   widget, Live Activity og Apple Watch gjennom delte modeller og tester.
9. **AUTO · KLAR** — Utvid før-lanseringstesten med kritiske ende-til-ende-
   scenarioer og dokumenter en repeterbar lanseringssjekk.

## Forslag som venter på godkjenning

Ingen.

## Ferdig

Ingen ennå.
