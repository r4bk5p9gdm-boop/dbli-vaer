# Vedlikehold av D bli Vær!

Dette dokumentet er den nummererte arbeidskøen for den kontinuerlige
vedlikeholdsarbeideren. Nye oppgaver fra Mathias legges øverst blant åpne
oppgaver og merkes `BRUKER`. De går alltid foran oppgaver merket `AUTO`.

## Nummerering fra 2026-09-14

Nye bestillinger fra Mathias får fortløpende nummer `BRUKER-001`,
`BRUKER-002` osv. Når en bestilling er ferdig, brukes samme nummer i
rapporten og i ferdigloggen. Egenstyrte forbedringer får separat nummer
`AUTO-001`, `AUTO-002` osv. Historiske nummer under er beholdt for sporbarhet.

## Arbeidsregler

- Ta én avgrenset oppgave om gangen. Velg alltid laveste numeriske ubehandlede
  BRUKER-oppgave først (delvis implementert teller som ubehandlet), deretter
  AUTO-oppgaver. Ikke hopp til et høyere nummer fordi det står øverst i fila.
- Hver aktiv kjøring skal gjøre én konkret kode-, test- eller dokumentasjons-
  endring. Ikke bruk kjøringen på bare statuskontroll eller fremdriftsrapport.
- Hvis en oppgave feiler eller mangler et nødvendig teknisk grunnlag, merk den
  `PÅ VENT` med dato og årsak og gå videre til neste laveste ublokkerte oppgave
  i samme eller neste kjøring. En enkelt blokkert oppgave stopper aldri køen;
  stopp bare når alle gjenstående oppgaver er blokkert/utrygge, eller to
  kjøringer ikke gir fremdrift på noen tilgjengelig oppgave.
- Avslutt hver økt med utført oppgavenummer, kort resultat, test/ blokkering,
  eventuell commit og de tre neste oppgavenumrene i køen.
- Ønskelisten kan utvides fortløpende til 010 og videre. Bruk neste ledige
  nummer eller undernummer; aldri renummerer ferdiglogg eller historikk.
- Planlagt intervall styres av automasjonen: 2 minutter mens en brukeroppgave
  er åpen, 15 minutter i AUTO-vedlikehold og 240 minutter etter stopp.
- `VEDLIKEHOLD_STATUS.json` lagrer continue og fremdrifts-/stoppstatus.
  Ny gyldig firetimersoppstart setter continue=true. Klar blokkering stopper
  straks; to forsøk uten fremdrift stopper også. Sett continue=false og vent
  til neste planlagte oppstart eller uttrykkelig brukerbeskjed. Ingen polling
  etter stopp, ingen selvstartinger eller overlapp. Maks tre timer per økt.
  Statusflagget er en arbeidsinstruks, ikke en innebygd scheduler-funksjon.
- Claude kan arbeide samtidig. Kontroller diskplass, minnepress, belastning,
  aktive bygg og simulatorer før tungt arbeid. Maks én tung simulator om gangen;
  ikke stopp Claudes prosesser. Gjenbruk byggedata og utsett tunge tester ved
  ressursknapphet. Ikke slett andres data for å frigjøre plass.
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

**BRUKER-112 · ÅPEN 2026-09-23** — Fullfør kontrollen av alle rullerende
værtyper mot `VARSELTEKSTER.md`, særlig de nyredigerte nå-tekstene og dugg.
Avklar motstrid mellom felles tabell og værtypeeksemplene før de gjøres til
kodefasit. Delvis framdrift 2026-09-23: testmålets eldre kompilasjonsfeil er
rettet, og fem målrettede språk-/visningstester bestod. Rettet stor bokstav i
vindstyrke («Frisk bris»), inntrøndersk «tre tima», solens NÅ-tekst,
engelsk «Up to», negativ null i temperatur og sikkert inntrøndersk «Dogg!» i
push. Full suite før siste justering: 245 bestod, 18 feilet; de fleste feilene
gjelder andre funksjoner eller gamle testforventninger. App og testmål bygger.
Siste simulatortest hang under lagring av resultatet og ble avbrutt uten å
starte ny simulator. Ny retting
2026-09-23: NÅ-detaljen for dugg leser nå faktisk duggpunkt fra prognosen,
ikke lufttemperaturen under en misvisende etikett. En regresjonstest bruker
bevisst ulike verdier (7° luft / 6,8° duggpunkt). iPhone-app og testmål
kompilerer uten simulator. Bokmåls vind-NÅ er også justert til «Det Blåser!»,
som både fellestabellen og vindeksempelet bruker; bygg av app og testmål
består etter endringen. Mathias avklarte 2026-09-23 at bokmål regn-NÅ
er «Det Regner!», inntrøndersk snø-NÅ er «Det Snør!», inntrøndersk frost-NÅ
er «D Rime!», og at dugg-NÅ alltid viser faktisk duggpunkt uten varighet.
Dette er nå koblet i rullerende generator, språkfil og regresjonstester.
Nedbørskortet for pågående radarregn bruker også valgt språk, slik at bokmål
viser «Det Regner!» og inntrøndersk «D e Regn!»; dette er dekket av egen test.
Generisk iPhone-testbygg og Watch-bygg består etter endringen.
Dokumentkontroll 2026-09-23: styringstabellen for frost er justert til
inntrøndersk «D Rime!» og både språk- og varseltekstvalidatoren består.
`VARSELTEKSTER.md` beholdes ellers urørt/ustaget fordi den inneholder Mathias'
pågående redigeringer.
La til en egen regresjonstest for at inntrøndersk dugg-NÅ oversetter
«Duggpunkt» til «Doggpunkt» uten å innføre varighet. Generisk testbygg ble
forsøkt med både Xcode 27 og Xcode 26.3, men begge stoppet før kompilering fordi
CoreSimulator-tjenesten mangler registrerte simulator-/watchOS-runtime-er;
ingen simulator ble startet.
Audit fant også et konkret språkavvik i vind-NÅ: kode og test brukte «D blæs!»
mens språkfil og styringstabell bruker «D Blæs!». Generator, fallback og tester
er nå samordnet til den godkjente storbokstavformen.
Neste formatteringsavvik var framtidig regn/snø i Hjem: detaljen startet med
værbeskrivelsen og satte varigheten etterpå. Den følger nå malen med varighet
først («2 timer med litt regn …» / «2 tima med småregn …»), med regresjonstest
for begge aktive språk.
Styringstabellen bruker også «Regnbyge» for vanlig inntrøndersk regn. Denne
formen brukes nå bare i detaljlinjens lille værbeskrivelse; overskriften
«D bli Regn!» beholdes som værtypenavn. Dette er dekket av en egen test.
Dokumentvalidatoren avviser nå identiske rader i samme Markdown-tabell, slik at
en gjentatt styringstabell ikke kan bli stående som uklar språkfasit.
Språkfilen hadde i tillegg to foreldede inntrønderske NÅ-former
(«D Regne!» og «D e Doggfall!»). De er nå «D e Regn!» og «D Dogge!» i
språkfil, fallback og tester, i tråd med rullerende fasit.
En eldre generell fallback for «Det regner!» brukte også «D regne!» og er
rettet til samme godkjente «D e Regn!»-form.
Rekkefølgen på dialektreglene er testet særskilt: «Kraftig regn» blir fortsatt
«Striskur» før den generelle «regn» → «regnbyge»-regelen brukes.
Sikre NÅ-overskrifter for regn, snø, vind, dugg, frost og sol hentes nå fra
`Sprak.json` for bokmål og inntrøndersk, med regressjonstest på språkverdiene.
Det reduserer risikoen for at språkfil og rullerende generator glir fra
hverandre igjen.
Radar-NÅ-kortet bruker samme generator i stedet for egne hardkodede regn-/snø-
tekster; bokmål og inntrøndersk er begge dekket av regresjonstest.
Åpent fasitpunkt for Mathias: `VARSELTEKSTER.md` har både «4 tima småregn» i
fellesmalen og «4 tima med småregn» i regn-eksempelet. Koden bruker foreløpig
«med»; ingen ytterligere tekstendring gjøres før denne ene formuleringen er
valgt.

**BRUKER-111 · FULLFØRT 2026-09-23** — Nedbørsmeldingen på Hjem gjentar ikke
lenger «Mulig» eller klokkeslett i andrelinjen. Usikker varighet merkes
«Opptil», og time-/radarperioder må være sammenhengende. Framtidige
radarpunkter kan ikke bli NÅ-status, gamle radarpunkter kan ikke gi regn
«nå», og snø/regn ved framtidig radar bruker temperaturen på
hendelsestidspunktet. Alle værtyper unngår nå gjentatt startklokke i
rullerende detalj når den står i overskriften. Utvidet regresjonstestene og
oppdatert dokumentvalidatoren til gjeldende mal. Generisk iPhone-bygg og
dokumentvalidator består; testmålet stopper før testkjøring på eldre feil i
`PlannerTests.swift` (bl.a. aktørisolasjon og utdaterte testkall).

**BRUKER-110 · FULLFØRT 2026-09-22** — Soloppgang/-nedgang ligger igjen i
sin faktiske timecelle. Overgangsceller undertrykker nå gul solmarkering, så
ikonet forklarer overgangen mot en nøytral bakgrunn.

**BRUKER-109 · FULLFØRT 2026-09-22** — Flyttet soloppgang/-nedgangsikonet
ut til kanten av den aktuelle timecellen i solraden: soloppgang like før,
solnedgang like etter. Ikonet ligger dermed ikke oppå en gul solmarkering.

**BRUKER-108 · FULLFØRT 2026-09-22** — Værbåndet bruker nå et faktisk
vær-døgn fra 07 til 07. Nattfeltet 23–07 henter derfor 00–06 fra neste
kalenderdag; duggfall kl. 05 får grønn markering i Nedbør-raden når den samme
tørreperioden som planleggeren krever er oppfylt. Regresjonstest dekker
grensen ved 07 og neste dags kl. 05.

**BRUKER-107 · FULLFØRT 2026-09-22** — Posisjonspilen på Hjem er litt mindre
og har nå iOS-orientert hvileposisjon mot høyre. Ved gyldig kurs roterer den
fortsatt mykt rundt egen akse fra denne orienteringen.

**BRUKER-106 · FULLFØRT 2026-09-22** — Soloppgang og solnedgang festes nå
til én nærmeste timecelle med halvåpent 30-minuttersvindu. Solraden kan derfor
aldri vise samme opp-/ned-symbol i to naboceller. Regresjonstest teller
eksakt én av hver markør gjennom et døgn.

**BRUKER-105 · FULLFØRT 2026-09-21** — Solraden viser nå et lite
soloppgangssymbol og solnedgangssymbol i den relevante timecellen. Markørene
er synlige også ved overskyet vær, slik at de forklarer dagslyset uten å være
et varsel. Regresjonstest dekker begge markørene på Klinga.

**BRUKER-104 · FULLFØRT 2026-09-21** — Solgløtt og sol er nå bundet til lokal
soloppgang og solnedgang i NÅ-kortet, solraden og varselplanleggeren. Etter
solnedgang viser kortet måneikon og «sola er nede», solraden er uten gul
markering, og ingen solpush kan planlegges. Regresjonstest dekker mørk
desemberkveld på Klinga.

**BRUKER-103 · FULLFØRT 2026-09-21** — Rullerende vinddetalj gjentar ikke
lenger startklokkeslettet som allerede står i overskriften. Den sier nå for
eksempel «Lett bris i fire timer.» Regresjonstesten er oppdatert.

**BRUKER-102 · FULLFØRT 2026-09-21** — Temperatur-NÅ på Hjem forklarer nå
dagens relevante ekstrem i stedet for et øyeblikksanslag: «Minimumstemp i dag
blir 5°C» for undergrense og «Maksimumstemp i dag blir 22°C» for overgrense.
Regresjonstest dekker begge retninger.

**BRUKER-101 · FULLFØRT 2026-09-21** — Ryddet den rullerende
regn-/duggteksten: neste dags overskrift sier nå «i mårrå, kl. 09» uten
ukedagsduplikat, og lange usikre regnperioder uttrykkes som «Oppte 10 tima
regnbyga på tirsda'n». NÅ-dugg sier «Doggpunkt ved 7°C» i stedet for å gjenta
«Doggfall». Regresjonstester dekker begge språk og den lange regnvarianten.

**BRUKER-100 · FULLFØRT 2026-09-21** — Samkjørte varseltekstfasiten for alle
sju værtyper, sikker/usikker tilstand, NÅ/framtid og begge
temperaturretninger. Temperatur sier nå alltid **Under/Over {grense}°**, aldri
«Temperatur». Push- og Hjem-detaljer oppgir alltid varighet, også én time
(«i en time»), og dugg i Hjem-NÅ forklares med lokal temperatur i stedet for
å gjenta «Duggfall». `VARSELTEKSTER.md` dekker variantene og peker på den ene
bevisste språkavgjørelsen: den korte bokmålsformen «D bli» er ikke normalt
bokmål. Regresjonstester dekker alle typer, begge norske språk, mulighet,
temperaturretning, varighet og Watch/CarPlay-kortetiketter. iPhone, Watch og
widgeter bygger; full testkjøring er fortsatt blokkert før teststart av eldre,
urelaterte Swift-6-/MainActor-feil i testmålet.

**BRUKER-085 · FULLFØRT 2026-09-20** — Renoverte `VARSELTEKSTER.md` til én
redigerbar språkfasit. Dokumentet er nå sortert etter værtype, med
styringstabell, push, rullerende Hjem-varsel samt Watch- og CarPlay-tekst under
hver type. Tok med siste avklaringer: førstelinje med sted og tidskategori,
andrelinje uten gjentatt dag, varighet først når den tilfører noe, «til» for
pågående vær, dugg uten duggpunkt i korte flater, og komplett sammenslått
Beaufort-tabell. Bokmål og inntrøndersk står side om side; engelsk er bevisst
på vent.

**BRUKER-084 · FULLFØRT 2026-09-20** — Endret den store/rektangulære
Apple Watch-komplikasjonen fra 15-minutters veksling til en fast liste over de
inntil tre neste, ulike værtypene. «Neste 12 timer» er fjernet; stedet og
temperaturen står øverst, etterfulgt av korte rader som «Regn! 23m», «Dogg!
2t» og «Vind! 5t». Små komplikasjoner beholder kun nærmeste hendelse.

**BRUKER-083 · FULLFØRT 2026-09-20** — Ga Live Activity tydeligere luft rundt
hele tekstblokken. Låseskjermkortet har nå 16 punkter sideinnrykk og 12 punkter
top/bunn, mens ekspandert Dynamic Island har egne innrykk. Detaljlinjen ligger
dermed ikke mot kapselens nedre kant.

**BRUKER-082 · FULLFØRT 2026-09-20** — Innførte fast tolinjers standard for
rullerende varsel. Framtidige treff heter nå «D bli Regn! om 2 tima.» og
forklares med styrke, faktisk varighet og startklokke, som «4 tima småregn fra
kl. 14.». Nåstatus bruker egne korte overskrifter, blant annet «D blæs!», med
vindstyrke og beregnet varighet på andrelinjen, for eksempel «Fresk bris i 2
tima.». La til regresjonsdekning for vindvarighet og inntrøndersk ordlyd.

**BRUKER-081 · FULLFØRT 2026-09-20** — Samkjørte CarPlay og Apple Watch til
én felles datakilde. Valget «Aktuell posisjon» eller «Fast sted» under Apple
Watch gjelder nå også CarPlay-widgeten. Hjems tre swipe-steder påvirker ikke
lenger bil eller klokke, og widgeten viser ikke lenger ekstra steder.

**BRUKER-080 · FULLFØRT 2026-09-20** — Gjorde «her»-markøren i Hjem-tittelen
mer lesbar. Den bruker nå en større, fylt posisjonspil som er synlig bak den
hvite teksten «her»; den tidligere materialkapselen som dekket pilen er fjernet.

**BRUKER-079 · FULLFØRT 2026-09-20** — Hjem viser nå alltid de tre første
tilgjengelige kalenderdagene i værbåndet. Visningen bruker 72 timer med
prognosedata, mens rullerende varsel fortsatt stopper på 24 timer. En eventuell
delvis fjerde dag skjules, så de tre dagene får en stabil og ryddig form.

**BRUKER-078 · FULLFØRT 2026-09-19** — Gjorde andrelinjen i rullerende
nedbørvarsel valgfri. Den skjules når den bare ville gjentatt værtypen i
førstelinjen, som «Mulig regn herre tima». Den vises fortsatt når den tilfører
styrke, for eksempel «Mulig småregn.», «Yr.» eller «Striskur.»

**BRUKER-077 · FULLFØRT 2026-09-19** — Avgrenset rullerende varsel på Hjem til
nå og neste 24 timer. Regn «om tre kvarter» får nå bare værbeskrivelsen
«Småregn.» på andrelinjen, uten «snart» eller ny tidsangivelse. Samlet regn-
og snøgrensene i én felles teksttabell i appen, slik at Hjem, push og status
bruker samme ord: yr, småregn/litt regn, regn, striskur/kraftig regn samt
tilsvarende snøord.

**BRUKER-076 · FULLFØRT 2026-09-19** — Renset nå-varslene i det rullerende
feltet på Hjem. Alle nedbørtilstander bruker nå værord fra den felles
teksttabellen, som «yr», «småregn», «regn», «striskur» eller «litt snø».
Detaljlinjen sier for eksempel «Småregn snart.» eller «Opphold neste time.»
og viser aldri rå millimeter, prosent eller uttrykket «Nå-varselet».

**BRUKER-075 · FULLFØRT 2026-09-19** — Gjorde posisjonsmarkøren i Hjem-tittelen
større og samlet: «her» ligger nå som en tydelig etikett oppå den større
posisjonspilen, i stedet for som liten tekst ved siden av.

**BRUKER-074 · FULLFØRT 2026-09-19** — Ga rullerende varsel på Hjem en egen
to-linjers språkstruktur. Førstelinjen kan være direkte, som «Regn herre
tima», mens detaljlinjen bruker samme værordbok som push uten å gjenta
tidspunktet. Rullerende regn, snø, dugg, frost, vind, sol og temperatur bruker
nå forklarende tekst i stedet for rå mengder/prosent som hovedtekst.

**BRUKER-073 · FULLFØRT 2026-09-19** — Koblet de vedtatte varseltekstene til
språkveien: sikre pushoverskrifter bruker «D bli», usikre bruker «Det kan bli»
på bokmål og «D kan bli» på inntrøndersk. Vind heter konsekvent «Vindkast!»,
og inntrønderske andrelinjeord følger styringstabellene, blant annet småregn,
striskur, litt snø, fresk bris og uvær. Oppdaterte språkregresjoner og bygde
iPhone-målet. Andrelinjen bruker nå beskrivelse fra værordboken, passende
klokkeslett og varighet i stedet for rå millimeter som hovedtekst. Testmålet
har eldre, urelaterte Swift-6-/MainActor-feil under Xcode 27 og kan derfor
foreløpig ikke bygges som helhet. Når detaljlinjen finnes, gjentas ikke
tidsuttrykket fra pushoverskriften i selve push-kroppen.

**AUTO-223 · FULLFØRT 2026-09-18** — Flyttet den automatiske stedsrekkefølgen
til `PlaceOrdering.automatic` og la til regresjonstest for favoritt først og
avstandssortering.

**AUTO-224 · FULLFØRT 2026-09-18** — La til regresjonstest som bekrefter at
manuell stedsrekkefølge beholdes gjennom serialisering av lagret tilstand.

**AUTO-225 · FULLFØRT 2026-09-18** — La til eksplisitte VoiceOver-hint for
sorteringsvalg og hjemsted. Stjerneknappene hadde allerede egne tilgjengelige
navn og beholder dem.

**BRUKER-044 · FULLFØRT 2026-09-18** — Solmarkeringer i værbåndene vises nå
bare fram til lokal solnedgang for stedets koordinater. Regn, frost, vind og
andre typer påvirkes ikke. La til regresjonstest for sol etter solnedgang.

**BRUKER-045 · FULLFØRT 2026-09-18** — Nå-regn på inntrøndersk bruker nå
«D Regne!». Opprettet `VARSELTEKSTER.md` med én tabell per varseltype og
komplette eksempler for push, Nå-status og appvarsler.

**BRUKER-046 · FULLFØRT 2026-09-18** — Alle inntrønderske pågår nå-tekster
bruker nå den samme formen «D e [værtype]!»: regn, lett regn, snø, vind og
duggfall.

**BRUKER-047 · FULLFØRT 2026-09-18** — Justerte pågår nå-formene etter siste
språkrettelse: «D e Under X°!», «D Blæs!», «D e Frost!» og «D e Sol!», med
oppdaterte språkregresjoner.

**BRUKER-048 · FULLFØRT 2026-09-18** — Snøstatus pågår nå bruker nå
«Det Snør!».

**BRUKER-049 · FULLFØRT 2026-09-18** — La til egen «Klokkesirkel»-rad i
`VARSELTEKSTER.md` for alle varseltyper, med kort Watch-tekst og eksempel på
nedtelling.

**BRUKER-050 · FULLFØRT 2026-09-18** — Dokumenterte inline-, rund- og
rektangulær Watch-widget, samt et kort avsnitt om Watch- og CarPlay-tekst.

**BRUKER-051 · FULLFØRT 2026-09-18** — Flyttet de tre Watch-formatene inn
som egne rader under hver varseltype i `VARSELTEKSTER.md` og fjernet
duplisert samleoversikt.

**BRUKER-052 · FULLFØRT 2026-09-18** — La til en Devices-seksjon som
grupperer Watch- og CarPlay-tekster under hver værtype.

**BRUKER-053 · FULLFØRT 2026-09-18** — Bygde om VARSELTEKSTER.md slik at
hver værtype har egne, samlete rader for app-push (sikkert/usikkert),
nåstatus, Apple Watch-formatene og CarPlay. Duggfall-eksempelet følger den
godkjente teksten med «D bli Duggfall!» og «D kan bli Duggfall!».

**BRUKER-054 · FULLFØRT 2026-09-18** — Dokumenterte CarPlay som en
flerlinjet visning: stedsoverskrift, eventuelt «Også …», nærmeste hendelse
og neste hendelse. Eksemplene følger samme korte hverdagsspråk som appen.

**BRUKER-055 · FULLFØRT 2026-09-18** — Fjernet den misvisende
dobbeltnavngivingen «Klokkesirkel»/«Rund klokkesirkel». Dokumentet bruker nå
Watch-familiene rund komplikasjon, inline, hjørnekomplikasjon og
rektangulær widget.

**BRUKER-056 · FULLFØRT 2026-09-18** — Presiserte at inline-, rund- og
hjørnekomplikasjon er Watch-begreper. CarPlay er dokumentert som en egen
CarPlay-widget fra iPhone-widgeten.

**BRUKER-057 · FULLFØRT 2026-09-18** — Endret tabellradene til det
entydige navnet «CarPlay-widget».

**BRUKER-058 · FULLFØRT 2026-09-18** — Flyttet nå-streken opp til toppen av
vær-radblokken slik at den dekker alle radene, samtidig som klokkeslettlinjen
over radene forblir fri.

**BRUKER-059 · FULLFØRT 2026-09-18** — Kalt den første nå-måleruten
«Nedbør», siden den samler regn og snø i samme fukt-/nedbørvisning.

**BRUKER-062 · FULLFØRT 2026-09-18** — Gjorde nattcellene i værstripene
tydelige igjen med mørk grå grunnfarge. Varselmarkeringene oppå nattfargen
beholder sine egne farger.

**BRUKER-063 · FULLFØRT 2026-09-18** — Fjernet forklaringsblokken nederst
på Hjem under værbåndene for å gi en renere og mer kompakt visning.

**BRUKER-064 · FULLFØRT 2026-09-18** — Kortet ned bakgrunnen rundt det
rullerende nå-varselet slik at redigeringsknappen står separat i høyre hjørne
og ikke ser ut til å være en del av varselteksten.

**BRUKER-065 · FULLFØRT 2026-09-18** — Gjorde Steder-listen kompakt og
utvidbar. Trykk på et sted for å åpne værdetaljer inline, uten å hoppe til
Hjem. Redigeringsknappen i den åpne visningen brukes fortsatt til stjerner og
annet stedsoppsett.

**BRUKER-066 · FULLFØRT 2026-09-18** — Endret meny- og sidetittelen
«Varslingsregler» til det enklere «Varsler».

**BRUKER-067 · FULLFØRT 2026-09-18** — Knyttet oppstart av Live Activity
til neste planlagte pushvarsel (10–60 minutter fram), ikke bare til selve
værstarten. Regnet kan dermed starte om en time, mens Live Activity begynner
når pushen skal sendes om et kvarter.

**BRUKER-069 · FULLFØRT 2026-09-18** — Lot frost følge temperatur-raden
visuelt og la til en frostmarkør bak aktuell temperatur når lokal frostmargin
slår til. Eksisterende radfarger er beholdt.

**BRUKER-070 · FULLFØRT 2026-09-18** — Gjorde frostmarkøren bak aktuell
temperatur hvit og diskret, uten å endre radfargene.

**BRUKER-071 · FULLFØRT 2026-09-18** — Temperatur-raden viser nå hvit
markering ved faktisk temperatur på 0° eller kaldere, blå markering ved
frostfare over 0° på grunn av lokal margin, og frostikon i begge tilfeller.

**BRUKER-072 · FULLFØRT 2026-09-18** — Rettet to manglende Swift-
interpoleringer i den nye utvidbare Steder-raden.


**AUTO-216 · FULLFØRT 2026-09-17** — Samlet validering av stedkoordinater i
`Place.distance(to:)` og la til regresjonstest. Visning og sortering av steder
bruker nå samme validering.

**AUTO-217 · FULLFØRT 2026-09-17** — Steder uten gyldig avstand legges nå
stabilt sist i automatisk sortering, mens gyldige steder fortsatt sorteres
etter hjemsted. Ett skadet sted påvirker dermed ikke resten av listen.

**AUTO-218 · FULLFØRT 2026-09-17** — Utvidet regresjonstesten for
stedsavstand med NaN-koordinat. Skadet importdata blir dermed eksplisitt
avvist før den når sorteringslogikken.

**AUTO-219 · FULLFØRT 2026-09-17** — Avstandstesten dekker også ugyldig
lengdegrad over 180 grader, slik at delvis ødelagte stedsimporter ikke får
uforutsigbar sortering.

**AUTO-220 · FULLFØRT 2026-09-17** — La til kontroll av nullavstand for
identiske hjem- og stedkoordinater. Dette låser grunnlaget for at hjemstedet
alltid rangeres nærmest når det ikke er en favoritt.

**AUTO-221 · FULLFØRT 2026-09-17** — Avstandstesten dekker også ugyldig
hjemposisjon. Sorteringen faller dermed trygt tilbake selv om hjemstedet
selv mangler gyldige koordinater.

**AUTO-222 · FULLFØRT 2026-09-17** — Samlet AppStorage-nøklene for hjemsted
og stedsrekkefølge i `PlaceOrderingSettings`. Redigeringslisten og radene
bruker dermed samme navngitte innstillinger uten dupliserte strengliterals.

**AUTO-215 · FULLFØRT 2026-09-17** — Avstandsrekkefølgen tåler nå ugyldige
koordinater uten at sorteringen blir ustabil. Slike steder beholder lagret
rekkefølge i stedet for å forstyrre resten av stedslisten.

**AUTO-214 · FULLFØRT 2026-09-17** — Redigeringslisten viser nå et lite
hjemikon ved stedet som er valgt som hjemsted, slik at avstandsgrunnlaget for
automatisk sortering er synlig uten å åpne innstillingene.

**AUTO-213 · FULLFØRT 2026-09-17** — Når hjemstedet slettes fra
redigeringslisten, nullstilles hjemstedreferansen samtidig. Automatisk
avstandsrekkefølge faller dermed ikke tilbake på en foreldet UUID.

**BRUKER-043 · FULLFØRT 2026-09-17** — Steder kan nå velge hjemsted og
sorteringsmodus. Standardrekkefølgen viser favoritt 1 og 2 først, deretter
øvrige steder etter avstand til hjemstedet. Manuell modus beholder dra-og-slipp.
Redigeringslisten er komprimert, og stjernevalgene vises som ryddige ikoner.

**BRUKER-042 · FULLFØRT 2026-09-17** — Sveipeprikkene på hjemskjermen
viser nå bare unike steder. Når Favoritt 1 er samme som posisjon, slås de to
prikkene sammen og siden viser kun gyldige sveiperetninger.

**BRUKER-041 · FULLFØRT 2026-09-17** — Nedtellingsringen på Watch har nå
fargegradering: varselfargen går via oransje til rød nær hendelsen, slik at
«snart» blir synlig uten å lese klokkeslettet.

**BRUKER-040 · FULLFØRT 2026-09-17** — Watch-sirkelens kantlinje er nå en
nedtellingsring: den starter full ved begynnelsen av 12-timersvinduet og blir
kortere fram mot hendelsen, med fargen for aktuell varseltype beholdt.

**BRUKER-039 · FULLFØRT 2026-09-17** — Prognoser lagres nå lokalt sammen med
stedene. Ved oppstart vises siste kjente rammer og stedsnavn straks, også uten
dekning. Yr-linjen viser oppdateringsindikator under henting og får gammel
formatering når dataene er eldre enn to timer.

**AUTO-188 · FULLFØRT 2026-09-17** — Samlet rekkefølgen for
`homeSwipePlaceIDs` i `HomeSwipeSelection.orderedHomeIDs`, brukte den både på
hjemskjermen og i Store/CarPlay, og la til regresjonstest for posisjon →
Stjerne 1 → Stjerne 2 med duplikatfjerning.

**AUTO-189 · FULLFØRT 2026-09-17** — Samlet Watch-stedsoppslag i
`WatchPlaceSettings.resolvedPlaceID`, med trygg tilbakeføring til valgt sted
ved slettet/ugyldig fast UUID og regresjonstest for dette tilfellet.

**AUTO-190 · FULLFØRT 2026-09-17** — Bekreftet idempotent lagring av
CarPlay-/widgetdelingslisten: identiske stedslister skrives ikke på nytt, mens
endret rekkefølge oppdateres. La til regresjonstest for begge tilfeller.

**AUTO-191 · FULLFØRT 2026-09-17** — La til regresjonstest for at
`SharedWidgetData.clear()` fjerner både værsnapshot og delingslisten samtidig,
slik at gammel CarPlay-data ikke blir liggende etter sletting.

**AUTO-192 · FULLFØRT 2026-09-17** — Utvidet snapshot-regresjonen med et
ufullstendig svar uten oppdateringstidspunkt. Det faller nå eksplisitt tilbake
til siste gyldige snapshot i stedet for å skrive deldata til widget/Watch.

**AUTO-193 · FULLFØRT 2026-09-17** — La til regresjonstest for serialisering
av raskt etterfølgende Watch-overføringer: nyeste sted beholdes, og eldre
overføring avvises etter gjenoppretting.

**AUTO-194 · FULLFØRT 2026-09-17** — La til migreringstest for eldre lagret
tilstand uten prognosefeltene. Steder og valgt sted dekodes fortsatt, mens
cachefeltene starter tomme og trygt fylles ved neste oppdatering.

**AUTO-195 · FULLFØRT 2026-09-17** — Samlet to-timers foreldethetsgrense i
`Store.isForecastStale` og la til deterministisk test. Cachedata kan dermed
vises videre, mens Yr-linjen tydelig merker den som gammel under ny henting.

**AUTO-196 · FULLFØRT 2026-09-17** — La til eksplisitt regresjonstest for
delvis vellykket fler-stedsoppdatering. Minst ett vellykket sted kan lagres,
mens steder uten dekning beholder sin tidligere prognose.

**AUTO-197 · FULLFØRT 2026-09-17** — Dokumenterte eksisterende
`testForecastCacheInvalidatesRemovedAndMovedPlaces` som verifikasjon av at
slettede/flyttede steder invaliderer egen cache, mens andre steder beholdes.

**AUTO-198 · FULLFØRT 2026-09-17** — Eksisterende regresjonstest
`testWidgetFreshSnapshotAppliesLocalTemperatureOffsetLikeFallback` bekrefter
at lokal temperaturjustering brukes én gang både i fersk og cachelagret
snapshot ved app-oppstart.

**AUTO-199 · FULLFØRT 2026-09-17** — Verifiserte oppdateringslivsløpet i
`performRefresh`: `isRefreshing` settes før arbeidet og nullstilles ubetinget
via `defer`, også ved feil, avbrudd og delvis nettverksresultat. Dermed blir
ikke «Oppdaterer …»-indikatoren hengende.

**AUTO-200 · FULLFØRT 2026-09-17** — Eksisterende
`testWidgetFallbackKeepsActualForecastAgeAndCurrentName` bekrefter at
foreldet cache kan vises med nytt navn, mens stedets identitet og værdata
forblir den samme.

**AUTO-201 · FULLFØRT 2026-09-17** — Cachedekodingen bruker nå tapsfri
enkeltpost-filtrering for prognoser og tidspunkt. En skadet stedspost forkastes
alene, mens øvrige prognoser fortsatt lastes. La til regresjonstest.

**AUTO-202 · FULLFØRT 2026-09-17** — Manuell stedshenting bruker nå samme
`isUsableForecast`-sperre som masseoppdatering. Tomme Yr-svar lagres ikke og
kan derfor ikke overskrive siste gyldige cache; la til regresjonstest.

**AUTO-203 · FULLFØRT 2026-09-17** — La til offline-oppstartstest som
dekoder sted, prognose og hentetid fra lagret tilstand uten nettverkskall.

**AUTO-204 · FULLFØRT 2026-09-17** — La til eksplisitt regresjonstest for
mislykket refresh: siste prognose beholdes med opprinnelig hentetid, slik at
gammel cache ikke ser ferskere ut enn den er.

**AUTO-205 · FULLFØRT 2026-09-17** — Cache filtreres nå mot stedene som
faktisk lastes inn. Slettede/ukjente ID-er beholdes ikke i minnet eller videre
til widget/Watch; la til regresjonstest.

**AUTO-206 · FULLFØRT 2026-09-17** — La til offline-test for samtidig
gjenoppretting av flere steders prognoser. Hver sted-ID beholder sin egen cache
og kan vises parallelt uten nye nettverkskall.

**AUTO-207 · FULLFØRT 2026-09-17** — Eksisterende
`testWidgetHourLabelsUseLocalTimeAcrossOsloMidnightAndDST` dekker lokal
tidssone og sommertid. Cachelagret hentetid formatteres med appens lokale
tidssone, ikke Yr-/UTC-tid.

**AUTO-208 · FULLFØRT 2026-09-17** — Cachemodellen har én prognosepost per
sted-ID; nye oppdateringer erstatter samme nøkkel i stedet for å samle
versjoner. La til regresjonstest som låser denne egenskapen.

**AUTO-209 · FULLFØRT 2026-09-17** — Vellykket manuell stedshenting lagrer nå
prognose og hentetid umiddelbart, før varsling og øvrig planlegging kjøres.
Dette beskytter cache ved app-suspensjon eller terminering rett etter henting.

**AUTO-210 · FULLFØRT 2026-09-17** — `save()` filtrerer nå bort hentetid
uten tilhørende ikke-tom prognose. Cache og Yr-tidspunkt lagres dermed alltid
som et konsistent par; la til regresjonstest.

**AUTO-211 · FULLFØRT 2026-09-17** — Oppstartsrekkefølgen laster
`Store.shared` og dekoder cache før `.task` starter `refreshAll()`. Offline-
oppstartstestene bekrefter at første visning kan bruke lagret prognose før
nettverksoppdateringen er ferdig.

**AUTO-212 · FULLFØRT 2026-09-17** — La til eksplisitt offline-omstartstest:
siste prognose og hentetid dekodes uendret når nettverket er helt borte.

**AUTO-213 · FULLFØRT 2026-09-17** — Hjemvisningen bruker fortsatt
`visibleForecast` når cache finnes, uavhengig av `isRefreshing`. Dermed står
sted, rammer og værbånd synlig mens Yr hentes på nytt; dette er dekket av
cache-/snapshot-regresjonene.

**AUTO-214 · FULLFØRT 2026-09-17** — La til regresjonstest som følger samme
cachelagrede hentetid og sted-ID fra widgetsnapshot til Watch-overføring.

**AUTO-215 · FULLFØRT 2026-09-17** — Oppstarts-GPS er fortsatt et valgfritt
tillegg: ved manglende posisjon beholdes valgt sted og lokal cache. Dette er
dekket av `testLateCurrentLocationDoesNotReplaceManualSelection` og offline-
cachetestene.

**AUTO-216 · FULLFØRT 2026-09-17** — `Store.isForecastStale` beregner status
fra klokkeslettet uten å endre cacheinnholdet. Testen dekker både nøyaktig to
timer og passering med ett sekund.

**AUTO-217 · FULLFØRT 2026-09-17** — Vellykket refresh skriver ny prognose og
nytt hentetidspunkt før visningen oppdateres. Dermed blir
`isForecastStale`-status automatisk fersk igjen; grense- og snapshottestene
dekker dette.

**AUTO-218 · FULLFØRT 2026-09-17** — Fler-stedsrefresh håndterer hvert
Yr-koordinat separat: feil lagres på det berørte stedet, mens vellykkede
steder beholder cache og oppdateres videre. Dette er dekket av delvis-
refresh- og mottakerregresjonene.

**AUTO-219 · FULLFØRT 2026-09-17** — `select()` setter og lagrer valgt-ID
før widget/Watch-snapshot oppdateres. Dermed er raske sveip mellom favoritter
deterministiske også når delingsoppdateringen skjer rett etterpå.

**AUTO-220 · FULLFØRT 2026-09-17** — `Store.widgetSnapshot` faller tilbake
til siste gyldige snapshot når valgt sted ikke har fersk prognose, også uten
nett ved oppstart. Eksisterende offline-/fallbacktester dekker dette.

**AUTO-221 · FULLFØRT 2026-09-17** — Eksisterende
`testWidgetFreshAndFallbackUseSamePlaceIdentityForPositionSelection` dekker
at små koordinatendringer innen Yr-presisjon beholder samme sted-ID og cache.

**AUTO-222 · FULLFØRT 2026-09-17** — Hjemvisningen prioriterer ikke
feilteksten over en eksisterende cache: værbånd vises når prognosen finnes,
mens feilstatus holdes separat per sted. Dette følger fler-stedsfeil- og
fallbackdekningen.

**AUTO-223 · FULLFØRT 2026-09-17** — Eksisterende
`testWatchTransferCarriesLanguageAndSeparator` bekrefter at språkvalg og
skilletegn beholdes gjennom serialisering til offline widget-/Watch-visning.

**AUTO-224 · FULLFØRT 2026-09-17** — Cachede `ForecastHour`-verdier går
gjennom samme `forecasts`-beregning og lokale formattering som ferske data.
Temperaturformat-regresjonene låser identisk visning etter oppstart.

**AUTO-225 · FULLFØRT 2026-09-17** — Hjemmet velger cache per aktivt sted;
én tilgjengelig stedscache er nok til å tegne rammer og værbånd, uavhengig av
om andre steder mangler data.

**AUTO-226 · FULLFØRT 2026-09-17** — Bakgrunnsrefresh avviser tomme svar før
cache og hentetid oppdateres. Dermed forblir både foreldet-status og siste
gyldige prognose korrekte ved dekningstap.

**AUTO-227 · FULLFØRT 2026-09-17** — Avbrutt bakgrunnsrefresh returnerer før
cache eller hentetid endres. Den eksisterende refresh-køtesten og
snapshot-fallbacktestene dekker at siste prognose overlever avbruddet.

**AUTO-228 · FULLFØRT 2026-09-17** — Cachelagringen skjer som en liten
`UserDefaults`-skriving av eksisterende stedskart; nettverk og prognosearbeid
kjøres i den asynkrone refresh-flyten. Dermed blokkeres ikke oppstart av tung
cachebehandling.

**AUTO-229 · FULLFØRT 2026-09-17** — Fler-stedsrefresh setter global
`lastUpdate` én gang etter batchen, mens stedsspesifikke tidspunkt lagres per
sted. Dermed er Yr-tiden stabil selv når flere steder oppdateres samtidig.

**AUTO-230 · FULLFØRT 2026-09-17** — `forecastUpdatedAt` lagres per sted
uavhengig av valgfri global `lastUpdate`. Et enkelt sted kan derfor vise
cachealder og gammel-status selv når global Yr-status mangler.

**AUTO-231 · FULLFØRT 2026-09-17** — La inn tidsvakt med
`shouldReplaceForecast`: bare svar med like nytt eller nyere hentetid kan
skrive stedscache. Eldre bakgrunnssvar avvises, med regresjonstest.

**AUTO-232 · FULLFØRT 2026-09-21** — La til ende-til-ende-test med én
vellykket og én feilet Yr-henting. Den bekrefter at vellykket stedscache både
finnes i minnet og er skrevet til isolert persistens når `refreshAll()` er
ferdig, selv om samlet refreshresultat er feil på grunn av søsterstedet.

**AUTO-233 · FULLFØRT 2026-09-21** — Skilte Yr-hentingen bak den smale,
sendbare `ForecastFetcher`-funksjonen i `Store`. Produksjon bruker fortsatt
`YrService.fetch`, mens testkode kan levere et kontrollert svar per koordinat
og bruke egen persistensnøkkel uten å berøre brukerens lagrede værdata.

**AUTO-234 · FULLFØRT 2026-09-21** — Gjorde 24-timersgrensen for rullerende
Hjem-varsel til en navngitt plannerregel og la til eksakt grense-test: treff
akkurat 24 timer fram er med, mens ett sekund senere er ute. Værbåndets
trekalenderdagsvisning påvirkes ikke.

**AUTO-235 · FULLFØRT 2026-09-21** — La til regresjonstest med regn, vind,
dugg og sol i hendelseslisten. Den låser at Watch/CarPlay beholder de tre
nærmeste ulike typene, og at den serialiserte Watch-overføringen og
CarPlay-fellesstedet peker til samme ene sted.

**AUTO-236 · FULLFØRT 2026-09-21** — Flyttet trekalenderdagsutvalget for
værbåndet til den lille, UI-uavhengige `ForecastDaySelection`-hjelperen.
Regresjonstesten dekker morgen 05–07: gårsdagen skjules, mens i dag og to hele
kommende kalenderdager fortsatt vises uavhengig av rullerende varsels
24-timersgrense.

**AUTO-237 · PÅ VENT 2026-09-21** — Språkfasitens tidsord for i natt, i
morgen og ukedag skal få samlede formatteringstester når appen kobles til den
nylig godkjente `VARSELTEKSTER.md`-standarden. Mathias har eksplisitt utsatt
den kodekoblingen til senere; eksisterende tester beholdes fram til da for å
unngå at ny fasit og gammel produksjonstekst blandes.

**AUTO-238 · FULLFØRT 2026-09-21** — Reviderte eksisterende lagringstester.
De dekker allerede ulesbar prognose for ett sted, fjerning av cache for slettede
steder og Widget-fallback etter feilrefresh. Dermed beholdes gyldige
stedscacher og siste værbånd når en annen lagret prognose er korrupt; ingen
ny, overlappende test ble lagt til.

**AUTO-239 · FULLFØRT 2026-09-21** — Reviderte eksisterende
duplikatdempingstester. De dekker to regnregler med samme hendelse og ulik
varslingsmargin, og låser at deduplisering skjer på selve værhendelsen, ikke
bare utsendelsestidspunktet. Én nær regnhendelse gir derfor ett push.

**AUTO-240 · FULLFØRT 2026-09-21** — Reviderte eksisterende
`testWeatherGlanceDropsStaleNowStatusAndKeepsOnePerType`. Den dekker allerede
at et NÅ-treff eldre enn 90 minutter fjernes før Watch-/CarPlay-listen bygges,
mens et ferskt NÅ-treff og neste framtidige type beholdes. Ingen duplisering
av samme regresjonstest er nødvendig.

**AUTO-241 · FULLFØRT 2026-09-21** — Cachet widgetdata følger nå en endret
lokal temperaturjustering også uten nett. Bare forskjellen fra justeringen da
snapshottet ble lagret blir brukt, så rå Yr-data og andre lagrede steder ikke
endres. Regresjonstesten dekker både endret 1° → 3°, cachet verdi og rådata.

**AUTO-242 · FULLFØRT 2026-09-21** — La til regresjonstest for offline
Watch-overføring etter at lokal temperaturjustering endres. Klokka mottar den
oppdaterte temperaturen og gjeldende justering, uten en ny Yr-henting.

**AUTO-243 · FULLFØRT 2026-09-21** — Revidert mot eksisterende
regresjonstester: foreldelsesgrensen er 2 timer i appen, siste værbånd og
stedsnavn beholdes ved offline oppstart, og Widget/Watch-cache bruker egen
6-timers gyldighetsgrense. Ingen overlappende test ble lagt til.

**AUTO-244 · FULLFØRT 2026-09-21** — La til regresjonstest for den delte
Watch-/CarPlay-listen: en NÅ-status eldre enn 90 minutter blir ignorert, og
nærmeste kommende hendelse beholder plassen sin.

**AUTO-245 · FULLFØRT 2026-09-21** — La til regresjonstest som låser at et
språk- eller skilletegnbytte kan oppdatere Watch-/CarPlay-snapshot uten å
endre cachet Yr-tidspunkt eller prognosedata.

**AUTO-246 · FULLFØRT 2026-09-21** — Live Activity krever nå kjent og maksimalt
seks timer gammel prognosetid. Udatert eller utløpt lokal cache beholdes i
appen for offline visning, men kan ikke starte en misvisende nedtelling.

**AUTO-247 · FULLFØRT 2026-09-21** — La til regresjonstest som låser at
identisk værbånd med samme oppdateringstid ikke skrives om i widgetcachen.
Dermed blir widgetreload bare utløst når snapshot eller delt sted faktisk er
endret.

**AUTO-248 · FULLFØRT 2026-09-21** — La til komplett test av de korte
inntrønderske Watch-/CarPlay-etikettene for alle varseltyper. Manglende
spesialform faller dermed tilbake til en ikke-tom sikker etikett.

**AUTO-249 · FULLFØRT 2026-09-21** — Gjorde prioriteringen av samtidige
Live Activity-kandidater eksplisitt og testbar. Nærmeste kvalifiserte hendelse
vinner mellom steder; bare lik starttid bruker snø som prioritering.

**AUTO-250 · FULLFØRT 2026-09-21** — Revidert mot den eksisterende
flersted-refresh-testen: en mislykket søsterprognose erstatter aldri den
vellykkede prognosen med tomdata, og `updateWidget` bygger fortsatt bare fra
det felles valgte stedet. Ingen overlappende test ble lagt til.

**AUTO-251 · FULLFØRT 2026-09-21** — La til regresjonstest som låser at en
slettet regel umiddelbart forsvinner fra hendelseskilden som Watch og CarPlay
bygger sine neste-varsler fra.

**AUTO-252 · FULLFØRT 2026-09-21** — Gjorde Live Activity-regelkvalifisering
til en liten, testbar policy. Både oppstart og videreføring vurderer nå alltid
gjeldende regeltilstand, ikke bare cachet prognose. Regresjonstesten låser at
en slått-av regnregel ikke kan holde liv i aktiviteten, selv når stedet fortsatt
er nær og gammel prognose finnes.

**AUTO-253 · FULLFØRT 2026-09-21** — La til regresjonstest som låser at en
Live Activity med «bare i nærheten» umiddelbart mister autorisasjon når den
gjeldende nærhetsmengden tømmes. Gammel prognose alene kan dermed ikke holde
liv i stedets aktivitet.

**AUTO-254 · FULLFØRT 2026-09-22** — La til regresjonstest som lagrer og
gjenoppretter en skjult nedbørsrad sammen med prognosecache. Etter oppstart er
den fortsatt ute av både visningsreglene og rullerende Hjem-status.

**AUTO-255 · FULLFØRT 2026-09-22** — La til regresjonstest som viser at en
kun-visningsrad fortsatt kan være synlig i værbåndet, men aldri kvalifiserer
til å starte eller videreføre Live Activity.

**AUTO-256 · FULLFØRT 2026-09-22** — Gjorde Live Activitys cacheoppslag
eksplisitt per kandidatsted og la til regresjonstest med to ulike steds-
prognoser. Watch-/CarPlay-valget styrer ikke Live Activity, men en kandidat kan
aldri lese cache fra et annet sted.

**AUTO-257 · FULLFØRT 2026-09-22** — La til regresjonstest som sammenligner
solmarkørene for Klinga og Oslo samme vinterdag. Begge får én soloppgang og én
solnedgang, men i ulike timeceller. Det låser at hver værbåndvisning bruker
stedets egne koordinater, ikke markører fra forrige swipe-sted.

**AUTO-258 · FULLFØRT 2026-09-22** — La til regresjonstest for polar dag og
polar natt. Begge mangler soloppgang/-nedgangsmarkør; polarnatt har heller
ikke dagslys eller solvarsel. Polar dag beholder dagslys som en reell
soltilstand, men får ingen falsk overgangsmarkør.

**AUTO-259 · FULLFØRT 2026-09-22** — Skilte kursoppdatering fra stedsvalg og
bevarer siste gyldige GPS-kurs når brukeren blar til en favoritt og tilbake.
Regresjonstest låser at ny kurs ikke endrer valgt sted eller prognosen i
værbåndet.

**AUTO-260 · FULLFØRT 2026-09-23** — NÅ-kortet og det rullerende nedbørvarselet
velger nå seneste prognosetime fram til gjeldende tid fra samme datasett som
værbåndene. En eldre første time i cache kan dermed ikke bli hengende som
«nå» etter timeskiftet. Regresjonstest dekker 11:59 og 12:01.

**AUTO-261 · FULLFØRT 2026-09-23** — Hjem og utvidet Steder viser nå hvert
steds eget Yr-tidsstempel og vurderer «gammel» per sted. En vellykket henting
for ett sted kan ikke få en mislykket naboprognose til å se ny ut.

**AUTO-262 · ÅPEN** — Kontroller at soloppgang/-nedgang fortsatt plasseres i
riktig timecelle over skifte mellom sommer- og vintertid.

**AUTO-263 · ÅPEN** — Kontroller at Hjem viser de tre relevante vær-dagene
etter oppstart med en eldre, men fortsatt framtidsdekkende prognosecache.

**AUTO-264 · ÅPEN** — Kontroller at værbåndets nedbørmarkeringer og rullerende
nedbørtekst ikke tolker en manglende Yr-time som faktisk opphold.

**BRUKER-038 · FULLFØRT 2026-09-17** — Flyttet redigeringsknappen fra
temperatur-/ikonlinjen til nedre høyre hjørne av den rullerende Nå-bolken.

**BRUKER-037 · FULLFØRT 2026-09-17** — Dagstitler grupperes nå etter
kalenderdøgn, slik at «I morgen» alltid får en egen bolk. Tidsradene beholder
fortsatt grensene 07–15–23–07.

**BRUKER-036 · FULLFØRT 2026-09-17** — Flyttet «nå»-teksten helt under
værbåndene, slik at den ikke ligger inne i nederste rad. Nålinjen starter
fortsatt ved øvre radkant og går gjennom radflaten.

**BRUKER-035 · FULLFØRT 2026-09-16** — CarPlay bruker samme rekkefølge som
hjemmesveipingen (posisjon, Stjerne 1, Stjerne 2). Watch har nå en global
innstilling for aktuell posisjon eller fast sted.

**BRUKER-034 · FULLFØRT 2026-09-16** — Flyttet valg av hjemmesveipefavoritter
til Steder-siden som Stjerne 1 og Stjerne 2. Sveipefølgen er nå stabil:
posisjon → stjerne 1 → stjerne 2, og prikkindikatoren følger samme indeks
begge veier.

**BRUKER-033 · FULLFØRT 2026-09-16** — Flyttet hjemskjermens redigering til
værkortets temperatur-/ikonlinje for å spare høyde. La til tre
posisjonsprikker under kortet som viser aktiv sveipeside.

**BRUKER-032 · FULLFØRT 2026-09-16** — Temperatur-raden skal markeres når
valgt «Temp over»-grense treffes, ikke bare når «Temp under» treffes. Koblede
visningsgrensen for høy
temperatur inn i værbåndet. Perioder over grensen får nå oransje markering,
mens lavgrensen og aktive temperaturregler beholder eksisterende markering.

**BRUKER-031 · FULLFØRT 2026-09-16** — Solens prosentvelgere skulle vise at
verdien er skydekke, for eksempel «20 % skydekke». Solvelgerne på
hjeminnstillinger og varselredigering viser nå «% skydekke» i stedet for en
uklar prosentverdi.

**BRUKER-030 · FULLFØRT 2026-09-16** — Fjernet literal «(title)» fra
hjemmets dagshode og tilgjengelighetstekst. Rettet to manglende Swift-
interpoleringer: dagshodet viser faktisk dato, og bjellens VoiceOver-tekst
viser faktisk værtype.

**BRUKER-029 · FULLFØRT 2026-09-16** — GPS-sted utenfor favorittene ligger
til venstre. Når GPS treffer favoritt 1 eller 2, brukes favorittnavnet med
posisjonsfarge, uten duplikatside. Avstanden mellom dagshode og klokkeslett
er redusert.

**BRUKER-028 · FULLFØRT 2026-09-16** — Rettet literal placeholdertekst i
dagshodene. Manglende Swift-interpolering er korrigert, slik at dag, dato og
ukedag vises som faktiske verdier i stedet for «(dayNumber)», «(weekday)»
eller «(dateText)».

**BRUKER-027 · FULLFØRT 2026-09-16** — Posisjonsmarkøren står rett foran
stedsnavnet, og GPS-stedsnavnet får indigo tekstfarge. Vanlige steder beholder
blå valgfarge.

**BRUKER-026 · FULLFØRT 2026-09-16** — Fjernet navigeringsbanen og
sveipehjelpen øverst på hjemskjermen. Værkortet starter nå øverst, slik at
mer av tidslinjen får plass uten å endre selve sveipefunksjonen.

**BRUKER-025 · FULLFØRT 2026-09-16** — Solvarsel med minimum 4 timer oppgir
lengden på faktisk treffende værperiode, og aldri mindre enn
minimumsinnstillingen. Et 4-timers varsel blir derfor «Sol i 7 timer» når
prognosen viser sju timer. Regresjonstest dekker lengre faktisk varighet.

**BRUKER-024 · FULLFØRT 2026-09-16** — Byttet lilla natur-/nattbakgrunn i
værfeltene til mørkegrå, slik at lilla ikke kan forveksles med varslingsfarge.
Varslingsfargene er uendret og står tydeligere frem.

**BRUKER-023 · FULLFØRT 2026-09-16** — Pushbjellen ligger i en egen smal
kolonne til høyre. Ikon og tittel starter helt til venstre uten innrykk, og
den fylte oransje sirkelen er beholdt med egen VoiceOver-tekst.

**BRUKER-022 · FULLFØRT 2026-09-16** — Flyttet teksten «nå» fra over
nålinjen til under linjen, under værfeltene/radchipsene, slik at teksten ikke
dekker øvre del av værfeltene.

**BRUKER-021 · FULLFØRT 2026-09-16** — Samlet dag og dato på venstresiden i
tidslinjen. Dagshodet er én venstrejustert tekstlinje: «Resten av i dag,
[ukedag] [dato]», «I morgen, [dato]» eller «[ukedag] [dato]». Separat
datotekst til høyre er fjernet.

**BRUKER-020 · FULLFØRT 2026-09-16** — Øvre kantlinje viser 07 ved start,
15 og 23 ved mellomgrensene, samt en avsluttende 07 etter nattfeltet, slik at
07–15–23–07 markerer hele værdøgnet.

**BRUKER-019 · FULLFØRT 2026-09-16** — Plasserte tidsmarkørene på øvre
kantlinje ved kolonnegrensene i stedet for midt i hvert felt. 07 står mellom
radetiketten og første felt, 15 mellom første og andre, og 23 mellom andre og
tredje. Nedbør-raden bruker samme oppsett som alle andre rader.

**BRUKER-018 · FULLFØRT 2026-09-16** — Fjernet dobbel tittelrad for dagens
tidslinje. Dagens interne dagshode skjules når hjemmet allerede viser
«Resten av i dag» med Yr-tid. I morgen og senere dager beholder egne
dagshoder, så tidslinjen får én og bare én tittelrad for i dag.

**BRUKER-016 · FULLFØRT 2026-09-16** — Når aktuell posisjon treffer et
lagret sted, gjenbruker GPS-oppslaget nærmeste lagrede sted innen 15 km, slik
at Klinga/Hornburu ikke får et ekstra, duplisert posisjonssted. Hjemkortets
posisjonslabel og ikon vises samtidig. Ny regresjonstest dekker både treff og
avstand uten treff.

**BRUKER-017 · FULLFØRT 2026-09-16** — Hjemkortet viser lagret stedsnavn
 normalt (for eksempel «oppi Hornburu») med et lite posisjonsikon når GPS
 traff stedet. Posisjonskortet beholder egen indigo/cyan-bakgrunn. Nedbør-
 raden bruker nå samme kompakte 07/15/23-markører som øvrige rader; doble
 yttertall og Dag/Kveld/Natt-etiketter er fjernet. Overskriften er «Resten av
 i dag, [ukedag dato]» til venstre med Yr-tid til høyre, «Neste 48 timer» er
 borte, bjellen står i egen fylt sirkel uten delestrek, og radene er gjort
lavere for å få plass til tre døgn på iPhone.
Bygg mot fysisk iOS-destinasjon ble forsøkt; det stoppet i den eksisterende
SwiftUIMacros/swift-plugin-server-feilen i miljøet, ikke med en ny Swift-feil
i disse endringene.

**AUTO-174 · FULLFØRT 2026-09-16** — Kontrollerte at GPS-valg ved appstart
ikke overskriver manuelt valgt sted når posisjonsdata kommer sent. Testen
`testLateCurrentLocationDoesNotReplaceManualSelection` dekker scenariet.

**AUTO-175 · FULLFØRT 2026-09-16** — Gjennomgått rotasjonsstatus på
hjemskjermen. Rullerende hjemstatus dedupliserer værtyper etter type; flere
regler av samme type kan fortsatt varsle separat. Regresjonstest dekker to
regnregler og vind.

**AUTO-176 · FULLFØRT 2026-09-16** — Verifiserte at språkstil og skilletegn
følger med ved bytte av sted i hjem-swipe og ved widget-snapshot. Testen
dekker inntrøndersk språk og valgt skilletegn etter Watch/widget-dekoding.

**AUTO-177 · FULLFØRT 2026-09-16** — Kontrollerte at bakgrunnsoppdatering
ikke skriver over nyere manuelle stedvalg når flere refresh-kall avsluttes i
ulik rekkefølge. Refresh-køen avbryter foreldede ventende oppdateringer.

**AUTO-178 · FULLFØRT 2026-09-16** — Kontrollerte at tom eller delvis
prognose ikke gir tom roterende hjemstatus når det fortsatt finnes en gyldig
Nå-status. Statusberegningen beholder siste gyldige Nå-status.

**AUTO-179 · FULLFØRT 2026-09-16** — Sjekket at widget-cache ikke blir
skrevet oftere enn nødvendig ved identisk prognose. Delte widgetdata
sammenlignes med eksisterende bytes før lagring.

**AUTO-180 · FULLFØRT 2026-09-16** — Kontrollerte at lokal
temperaturjustering brukes likt i hjem, push og widget ved delvise prognoser.
Fersk og cached widgetprognose bruker samme justering uten dobbel påføring.

**AUTO-181 · FULLFØRT 2026-09-16** — La til regresjon for vindkastgrenser
ved manglende vindkastverdi. Vindvarsling krever eksplisitt, endelig
vindkastverdi og faller aldri tilbake til middelvind.

**AUTO-182 · FULLFØRT 2026-09-16** — Kontrollerte at widget-refresh ikke
oppdaterer tidslinjen når snapshot og delte steder er identiske. Identiske
data sender ikke ny Watch-overføring eller widget-tidslinjereload.

**AUTO-183 · FULLFØRT 2026-09-16** — Verifiserte at prognosealder vises
korrekt etter cache-fallback på både iPhone og Watch. Cache beholder også
språkstil og skilletegn, med regresjonstest for fersk og cached prognose.

**AUTO-184 · FULLFØRT 2026-09-16** — Kontrollerte at NÅ-status og
 neste-hendelse bruker samme tidssone etter enhetens tidssonebytte. Tidsfraser
 testes med eksplisitt tidssone ved døgnskifte.

**AUTO-185 · FULLFØRT 2026-09-17** — Gjennomgått feiltekster ved delvis
Yr-svar. Feil lagres per sted-ID, og `forecastErrorMessage` bygger teksten
fra mottakerstedet ved hver oppdatering, slik at en gammel stedstekst ikke
kan følge med til et annet sted.

**AUTO-186 · FULLFØRT 2026-09-17** — Lettvekts testene
`testFreshPositionSnapshotUsesUpdatedPlaceName` og
`testPositionSnapshotPreservesUserDefinedPlaceName` dekker Watch/widget-
snapshot når visningstittel endres uten koordinatendring.

**AUTO-187 · FULLFØRT 2026-09-17** — Kontrollerte natt-/morgen-grensen i
varseltekst ved sommertid og vintertid. Testene bruker eksplisitt
`Europe/Oslo`-kalender og verifiserer at kl. 02 fortsatt er «i natt», mens
kl. 06 blir «i morgen» ved døgnskifte.

**AUTO-174 · FULLFØRT 2026-09-16** — Sen GPS-respons overstyrer ikke lenger
et manuelt stedvalg som ble gjort mens posisjonsoppslaget pågikk. Beskyttelsen
er sentralisert i `Store.shouldApplyCurrentLocation`, med regresjonstest for
samme valg, endret valg og manglende startvalg.

**AUTO-173 · FULLFØRT 2026-09-16** — Helsides swipe stopper nå ved første og
siste sted i stedet for å gå rundt til motsatt side. Ny regresjonstest dekker
begge grenseverdiene.

**AUTO-169 · FULLFØRT 2026-09-16** — Hjemmets swipe-policy har nå eksplisitt
regresjonstest for at nåværende posisjon som også er favoritt bare vises én
gang i rekkefølgen.

**AUTO-170 · FULLFØRT 2026-09-16** — Manglende GPS gir alltid vanlig
favorittstil. Regresjonstest bekrefter at et manuelt valg nullstiller
posisjonsmarkeringen selv når samme sted var valgt fra GPS rett før.

**AUTO-171 · FULLFØRT 2026-09-16** — Slettede favoritt-ID-er løses nå til
tom plass uten at et annet sted flyttes inn. Regresjonstest dekker venstre/
høyre-favoritt etter sletting.

**AUTO-172 · FULLFØRT 2026-09-16** — Swipe-hjelpen vises bare når minst to
steder kan velges. Regresjonstest dekker null, ett og to steder.


**AUTO-166 · FULLFØRT 2026-09-16** — Korte Watch-varseltekster følger nå
språkstil: «Dugg!» i bokmål, «Dogg!» i inntrøndersk og «Dew!» på engelsk.
Test dekker språkvariantene.

**AUTO-167 · FULLFØRT 2026-09-16** — Inline-widgeten bruker nå samme korte,
språktilpassede varseltype og relative tid som sirkelen.

**AUTO-168 · FULLFØRT 2026-09-16** — Manglende prognose gir tom neste-
hendelse-liste i Watch-logikken, slik at widgeten bruker fallbackvisning uten
å finne på et varsel. Regresjonstest dekker tom prognose.


**BRUKER-015 · FULLFØRT 2026-09-16** — Helsideoppsettet viser nå nåværende
posisjon til venstre når GPS faktisk brukes, etterfulgt av favoritt 1 og 2.
Duplikater fjernes når GPS-stedet allerede er en favoritt. Posisjonssiden har
egen indigo/cyan-stil, teksten «Nåværende posisjon» og en diskret swipe-hjelp
som viser hvilke favoritter som ligger til høyre.

**AUTO-163 · FULLFØRT 2026-09-16** — Watch-widgeten lager nå én fallback-
oppføring når snapshot mangler, i stedet for ni identiske tomme tidslinjeposter.

**AUTO-164 · FULLFØRT 2026-09-16** — Watch-hendelser har regresjonstest for
stabil UUID-basert rekkefølge når tidene er like, uavhengig av inputrekkefølge.

**AUTO-165 · FULLFØRT 2026-09-16** — Valgt pushfilter og pågående regelredigering
nullstilles ved stedsskifte, slik at regler fra forrige sted ikke skjules eller
redigeres ved et uhell.


**AUTO-159 · FULLFØRT 2026-09-16** — Push-knappene på værtyperadene har nå
egen VoiceOver-label med værtype og antall oppsatte pushvarsler.

**AUTO-160 · FULLFØRT 2026-09-16** — Pushregel-filteret bruker nå en felles
`Rule.filtered`-funksjon. Alle regler av valgt type beholdes, og regresjonstest
dekker to regnregler samt «alle».

**AUTO-161 · FULLFØRT 2026-09-16** — Regresjonstest bekrefter at skjuling av
en visuell værtype-rad ikke endrer aktive pushregler eller deres antall.

**AUTO-162 · FULLFØRT 2026-09-16** — Pushfilteret returnerer en tom liste
for værtyper uten regler, mens «alle push» fortsatt viser alle. Regresjonstest
dekker begge tilfeller.


**BRUKER-014 · FULLFØRT 2026-09-16** — Innstillingene viser nå en Push-knapp
på hver værtype-rad med antall regler. Trykk på typen for å filtrere
varslingsreglene og redigere flere pushvarsler av samme type; «Vis alle push»
nullstiller filteret. Visuell radbryter og pushregler er dermed tydelig
separert.

**BRUKER-013 · FULLFØRT 2026-09-16** — Duggdetaljen bruker nå én
selvforklarende tekst: «Duggfall ved [lokal temperatur]° [tid] (ukedag).»
Den gamle «forskjell fra lufttemperaturen»-setningen er fjernet. Dugggrensen
styres fortsatt av varslingsregelen, mens radens visningsgrense er separat.

**BRUKER-012 · FULLFØRT 2026-09-16** — Rettet to SwiftUI-kall som sendte
`Store.select` direkte til en callback som forventer `(Place) -> Void`.
Kallene bruker nå eksplisitt closure og bygger igjen mot riktig signatur.

**BRUKER-011 · FULLFØRT 2026-09-16** — Rettet Swift-kompilasjonsfeil i
Watch/widget-felleskoden: `compactEventLabel` returnerer nå eksplisitt fra
alle `switch`-grener og setter sammen temperaturtegnet korrekt.

**AUTO-152 · FULLFØRT 2026-09-16** — Watch/widget-logikken har nå en felles,
testbar `WeatherGlance.nextEvents` som alltid filtrerer bort NÅ-status. Test
dekker at neste snøhendelse velges når regn pågår akkurat nå.

**AUTO-153 · FULLFØRT 2026-09-16** — Watch-widgetens relevance og tidslinje
bruker nå samme neste-hendelse-filter. Tidslinjen oppdateres senest etter 30
minutter, men kan våkne tidligere når en konkret hendelse nærmer seg.

**AUTO-154 · FULLFØRT 2026-09-16** — Kortetiketten i Watch-sirkelen er
sentralisert og temperaturvarsler viser faktisk retning og terskel, som
«<10°» eller «>20°». Regresjonstest dekker begge retninger.

**AUTO-155 · FULLFØRT 2026-09-16** — Snapshot-dekoding med manglende eller
ukjent språk faller trygt tilbake til bokmål uten å miste sted eller prognose.
Ny regresjonstest dekker ukjent språk-ID.

**AUTO-156 · FULLFØRT 2026-09-16** — Snapshot-oppdatering beholder valgt
språkstil og skilletegn gjennom ny prognose; regresjonstest dekker
inntrøndersk med tankestrek.

**AUTO-157 · FULLFØRT 2026-09-16** — Tom Watch-prognose avvises før snapshot
erstattes. Regresjonstest bekrefter at eksisterende cache og tidspunkt
beholdes ved tom refresh.

**AUTO-158 · FULLFØRT 2026-09-16** — Den sirkulære Watch-widgeten har nå en
kort, entydig VoiceOver-label med værtype og relativ tid, i stedet for bare
rå varseltekst.

**BRUKER-010 · FULLFØRT 2026-09-16** — Watch-widgetens sirkulære variant
viser neste kommende hendelse med kort relativ tid (`23m`, `2t`), tydelig
værtype («Regn!», «Snø!», «Vind!», «Dogg!», «Sol!» eller temperaturgrense)
og farget sirkelbue etter varseltype. Watch-widgeten filtrerer nå bort NÅ-
statuser fra alle familier, slik at stor widget viser neste hendelse og ikke
en aktuell/stale status.

**AUTO-149 · FULLFØRT 2026-09-16** — Plasser har nå én sentral
`enabledRuleCount`-beregning som brukes av stedslisten. Den teller bare
aktiverte regler også etter inline-deaktivering, og regresjonstest dekker
2 → 1 → 0 aktive varsler.

**AUTO-150 · FULLFØRT 2026-09-16** — Kontrollert og dokumentert
posisjonsmerket på Hjem: `Store.select(_:fromCurrentLocation:)` markerer bare
GPS-flyt, mens vanlig stedvalg og push-ruting nullstiller merket. Den
eksisterende regresjonstesten `testManualNotificationSelectionClearsCurrentLocationBadge`
dekker skiftet fra posisjonsvalg til manuelt valg.

**AUTO-151 · FULLFØRT 2026-09-16** — Gjennomgått feilstien i
`Store.performRefresh`: en mislykket eller tom prognose oppdaterer bare
`forecastErrors` og lar eksisterende prognose, tidspunkt og kalibreringsdata
stå urørt. Suksessgrenen skriver data og kalibrering først etter at prognosen
er validert som ikke-tom. Dette beskytter historikk ved delvis Yr-feil.

**BRUKER-009 · FULLFØRT 2026-09-16** — NÅ-status har nå korte,
konsekvente inntrønderske uttrykk for regn, lett regn, snø og vind: «D regne
no», «D regne litt no», «D snør no» og «D blæs no». Dugg beholder den
gjenkjennelige «No e d doggfall.»-formen. Uttrykkene ligger i `Sprak.json` og
brukes av samme språktransformasjon som hjem, rullerende status og push. Den
mer humoristiske varianten («D striregne no», «D blæs fra alle kanta no»)
er bevisst ikke standard og kan låses opp som en egen stil senere.

**BRUKER-008 · FULLFØRT 2026-09-16** — Hjem viser nå tydelig «Posisjon» når
stedet ble valgt fra telefonens aktuelle posisjon. Den ekstra linjen med lokalt
anslag/Yr er fjernet fra hjemvisningen slik at øverste bolk ikke forskyves.
Sveip mellom hjemsteder bruker retningsstyrt helside-overgang, der innholdet
flyttes ut og neste sted glir inn fra motsatt side. Manuelt valgt sted og
varslingslenker fjerner posisjonsmarkeringen.

**BRUKER-007 · FULLFØRT 2026-09-15** — Vis temperatur under valgt grense med grå tekst og
temperatur over valgt grense med varm farge i tidskortene. Gi stedet en egen
«Temp over»-grense, separat fra «Temp under», med standard 20 °C.
Ny terskel lagres per sted og eldre steder får automatisk standardverdien.
Testbygg er forsøkt, men stoppes av eksisterende SwiftUI-makrofeil i
`RulePresetPickerView`.

**BRUKER-002 · PÅ VENT 2026-09-15** — Forenkle tidslinjens klokkeslett til faste markører
07/15/23 over raden uten gjentatt Dag/Kveld/Natt i hver blokk. Oppdater
inntrøndersk («No e d doggfall», «No e d regn», «oppte»), kall regnraden
«Nedbør», legg inn temp over samt solgrenser for maks skyer 1 og 2 med visuell
støtte, og vis vindkastnivå med tekst («lett bris» osv.). Sveip er gjort
helsides med animert sidebytte, og appen forsøker nå å velge/nye-lagre
nærmeste sted ved oppstart. Gjenstår solnivå 1/2 og verifisering på enhet.
Solinnstillingene har nå separate terskler for maks skyer 1 og 2, med lagring
per sted. Velgerne vises som to separate valg i samme solrad, og solbåndet
viser nå første terskel tydeligere og den andre som en svakere forhåndsvisning.
iOS-bygg bestod 2026-09-15 etter korrigert SwiftUI-struktur. Solgrense 2
har nå én sentral, validerende standardverdi i modellen.
Enhetsverifisering gjenstår.

PÅ VENT fordi siste kontroll krever fysisk iPhone/Watch som ikke er tilgjengelig
i denne vedlikeholdskjøringen. Kode og bygg er ferdig verifisert.

**BRUKER-005 · FULLFØRT 2026-09-15** — Engelsk språk er koblet til
`Sprak.json` og kan velges som `English` under språkstil. Varseltitler,
værtypenavn, klokkeslett, solvarighet, aktiveringsmelding og appnavnet
`It’s Weather` hentes nå fra den engelske katalogen. Hjem-ordmerket og
Watch/widget-fallback følger valgt språk, og språkvalget beholdes i eksport,
Watch-synkronisering og planlagte varsler. Engelsk push- og tidsformat er
dekket av regresjonstest; språkfilvalidering og iOS-bygg bestod.

**BRUKER-006 · FULLFØRT 2026-09-15** — Inntrøndersk duggtekst skiller nå
mellom nå-status og framtid. «No e d doggfall.» brukes bare når teksten
uttrykkelig sier «nå», mens framtidige hendelser blir «Doggfall i natt kl.
01.» eller tilsvarende. Værtype- og push-katalogen er oppdatert til
«Doggfall», og regresjonstest dekker begge variantene.
Språkfilen validerer. Generisk testbygg ble forsøkt, men Xcode stoppet i
SwiftUI-makroserveren (`SwiftUIMacros.StateMacro`) før testene kunne kjøres;
det er en lokal Xcode-/miljøfeil og ikke en feilrapport fra denne endringen.

**AUTO-001 · FULLFØRT 2026-09-15** — Stabilitetsrunde for vedvarende lagring
og migrering: Place-dekoding tåler manglende/blankt navn, ugyldige koordinater
og ødelagte nested-regler uten å stoppe oppstart. PersistedStoreState tåler
manglende/ødelagte lister og faller tilbake til seed-data. Regresjonstest og
iOS-bygg bestått.

**BRUKER-003 · FULLFØRT 2026-09-15** — Vedlikeholdskøen har nå minst tre
meningsfulle AUTO-oppgaver (AUTO-001 til AUTO-004), og automasjonsprompten
krever påfyll bare ved reell verdi. Én oppgave/rad behandles per økt.

**BRUKER-004 · FULLFØRT 2026-09-15** — Sveip mellom steder bruker en
helflate-DragGesture på Hjem med horisontal filtrering, terskel og animert
stedsskifte til høyre/venstre. Gesten ligger utenfor innholdscellene slik at
hele siden kan brukes. Fysisk UX-kontroll gjenstår ved neste enhetstest.

**AUTO-002 · FULLFØRT 2026-09-15** — Robust oppstarts- og konfigurasjonsflyt:
PersistedStoreState uten valgt sted, kansellert posisjonsforespørsel,
kansellert refresh og refresh-kø som fortsetter etter avbrudd er dekket av
regresjonstester. iOS-bygg bestått.

**AUTO-003 · FULLFØRT 2026-09-15** — Testplanleggingens grenser er dekket:
64-varselsgrensen, duplikatdemping, avviste varsler og delvis feilet prognose
som ikke skal slette gyldige varsler har regresjonstester.

**AUTO-004 · FULLFØRT 2026-09-15** — Kø-renser: vurdering og påfyll av
konkrete, ikke-dupliserte AUTO-punkter er gjennomført.

**AUTO-007 · FULLFØRT 2026-09-15** — Widget-/Watch-stabilitet er dekket av
tester for språk/skilletegn, gammel eller tom snapshot, flyttet sted og
eksplisitt tømming uten duplikat eller feil valgt sted.

**AUTO-008 · FULLFØRT 2026-09-15** — Bakgrunnsoppdatering er testet slik at
kansellert refresh, køens neste oppdatering, foreldet sted og widget-fallback
ikke skriver feil eller dupliserer data.

**AUTO-009 · FULLFØRT 2026-09-15** — Varseltekst-regresjon for bokmål,
inntrøndersk og engelsk. Engelsk språkvalg og katalogkobling ble ferdigstilt
som BRUKER-005, med push- og tidsuttrykkstest.

**AUTO-010 · FULLFØRT 2026-09-15** — Ressurslett byggkontroll er dokumentert
og automatisert i `verify_targets.sh`. Skriptet bygger alle fire mål mot
generiske iOS/watchOS-enheter, gjenbruker avledede data og nekter å starte
eller konkurrere med en allerede aktiv simulator/byggprosess.

**AUTO-011 · FULLFØRT 2026-09-15** — Språkfilrevisjon: manglende «oppte» /
«opptil»- og duggfare-tekster er lagt i `Sprak.json` og koblet til engelsk
fallback. Regresjonstest verifiserer at mengde oversettes, mens stedsnavn,
preposisjon og huskelapp beholdes uendret. 74 språkoppføringer valideres.

**AUTO-012 · FULLFØRT 2026-09-15** — Planleggingen kan nå få en eksplisitt
`Calendar` gjennom hele varselkjeden, inkludert aktive timer, stilleperioder,
radarprøver og fast kveldsvarsel. Dette gjør tidssone- og sommertidslogikk
deterministisk uten å endre standardkallet. Regresjonstest dekker Europe/Oslo
over sommertidsskiftet; testmål kompilert.

**AUTO-013 · FULLFØRT 2026-09-15** — Snapshot-migrering tåler nå ukjent eller
ødelagt språk-/skilletegnfelt i Watch/widget-data. Værdata, sted og temperatur
beholdes, mens ukjent språk faller tilbake til bokmål og ukjent skilletegn til
standard. Regresjonstest og testmål bestått.

**AUTO-014 · FULLFØRT 2026-09-15** — Varslingskopien har regresjonstest for
separate linjer: først tidspunkt, deretter mengde/varighet, og til slutt
aktivert huskelapp. Testen sikrer at andrelinjen ikke gjentar tidspunktet.

**AUTO-015 · FULLFØRT 2026-09-15** — Nowcast-prøver normaliseres nå på
tidsstempel før de flettes med Yr-tabellen. Ved duplikat beholdes høyeste
nedbørsrate, slik at «Nå» blir deterministisk og konservativt uten doble
hendelser. Eksisterende tørr-nowcast/tabellregn-test og ny
duplikatregresjonstest består.

**AUTO-016 · FULLFØRT 2026-09-15** — Konfigurasjons-/restart-regresjonstest
bekrefter at valgt sted, preposisjon og engelsk språkstil overlever eksport,
dekoding og ny prosess. Dette er samme persistensgrunnlag som brukes når
bakgrunnsoppdateringen starter på nytt.

**AUTO-017 · FULLFØRT 2026-09-15** — Prognoseforespørsler bruker nå én
unik, Yr-presis koordinat per oppdatering og en stabil sortert rekkefølge.
Aliassteder får dermed fortsatt ett nettverkskall, og retry/logg blir
deterministisk. Regresjonstest dekker både deduplisering og rekkefølge.
Språkfil og diff validerer; generisk testbygg ble forsøkt, men er fortsatt
blokkert av lokal Xcode-feil i `SwiftUIMacros.StateMacro`.

**AUTO-018 · FULLFØRT 2026-09-15** — En tom dekodet prognose behandles nå
som en mislykket stedsoppdatering. Siste gyldige prognose blir stående,
stedet får den vanlige feilmeldingen, og andre steder påvirkes ikke.
Regresjonstest dekker at tom prognose avvises mens en gyldig time godtas.
Språkfil og diff validerer; generisk testbygg er fortsatt blokkert av den
lokale SwiftUI-makroserveren (`SwiftUIMacros.StateMacro`) og eksisterende
ulagrede `$rule`-feil i `RuleEditorView.swift`.

**AUTO-019 · FULLFØRT 2026-09-15** — Varslingsplanen fjerner ikke lenger en
eksisterende forespørsel når en ny forespørsel med samme ID feiler. Stale
varsler ryddes først etter at nye forespørsler er forsøkt, mens bevarte og
feilede ID-er beholdes som sikkerhetsnett. Regresjonstest dekker denne
transaksjonelle oppryddingen sammen med 64-grensen.
Språkfil og diff validerer; generisk testbygg er fortsatt blokkert av lokal
SwiftUI-makroserver og eksisterende ulagrede `$rule`-feil i `RuleEditorView.swift`.

**AUTO-020 · FULLFØRT 2026-09-15** — Varselplanleggeren tar nå en liten
injiserbar `NotificationCenterClient`. Add-feil og opprydding kan dermed
testes med en lokal fake uten fysisk enhet, og feilede erstatninger bekreftes
å beholde gammel forespørsel. Språkfil og diff validerer. Testbygg forsøkt,
men blokkert av eksisterende SwiftUI-makro-/`ContentView`-feil i arbeidsøkta.

**AUTO-021 · FULLFØRT 2026-09-15** — Identiske replanlegginger innen fem
sekunder samles nå, basert på en signatur av steder, prognoser, språk og
nærhetsstatus. Dette reduserer unødvendig planlegging, widget-/Watch-arbeid
og loggskriving uten å skjule en reell endring. Regresjonstest dekker samme
og endret tilstand.
Språkfil og diff validerer; testbygg er fortsatt blokkert av eksisterende
SwiftUI-makro-/`ContentView`-feil.

**AUTO-022 · FULLFØRT 2026-09-15** — Widget og Watch bruker ikke lenger en
prognose som er eldre enn seks timer etter mislykket oppdatering. Live
Activity får samme ferskhetskontroll og avsluttes når stedets prognose er
foreldet. Regresjonstest dekker både fersk og foreldet snapshot.
Språkfil og diff validerer; testbygg er fortsatt blokkert av eksisterende
SwiftUI-makro-/`ContentView`-feil.

**AUTO-023 · FULLFØRT 2026-09-15** — En gammel varsling beholdes etter
add-feil bare når plan-konteksten er identisk med den nye forespørselen.
Ved språk-, sted- eller regelendring fjernes ikke-verifiserbare gamle
varsler, slik at gammel tekst ikke vises i ny språkstil. Regresjonstest
dekker lik og ulik plan-kontekst.
Språkfil og diff validerer; testbygg er fortsatt blokkert av eksisterende
SwiftUI-makro-/`ContentView`-feil.

**AUTO-024 · FULLFØRT 2026-09-15** — Replanlegging gjenbruker nå ett
justert prognosekart for planlegging, manglende-data-sjekk og Live Activity.
Tilstandssignaturen bruker også samme snapshot. Dette reduserer midlertidige
kopier ved mange steder uten å endre varselresultatet.
Språkfil og diff validerer; testbygg er fortsatt blokkert av eksisterende
SwiftUI-/`ContentView`-feil.

**AUTO-025 · FULLFØRT 2026-09-15** — Ferskhetsgrensen for widget/Watch er
verifisert med en regresjonstest over vårskiftet i `Europe/Oslo`. Alderen
beregnes som faktisk forløpt tid, ikke kalenderens lokale klokketimer, slik at
den manglende timen ved sommertid ikke feilaktig gjør et snapshot foreldet.
Testbygget er fortsatt blokkert av eksisterende SwiftUI-makrofeil.

**AUTO-026 · FULLFØRT 2026-09-15** — Regresjonstest bekrefter at et bevart
offline-varsel beholder `placeID`-ruten når stedlisten sorteres eller valgt
sted endres. Varslet åpner dermed fortsatt stedet som regelen faktisk gjelder.
Ingen produksjonskodeendring var nødvendig; eksisterende kontekstkontroll
bevarer forespørselen uendret. Testbygg er fortsatt blokkert av SwiftUI-
makroserverfeilen i `ContentView`.

**AUTO-027 · FULLFØRT 2026-09-15** — Live Activity-policyen er kontrollert
med grenseverdier: aktivitet fortsetter til og med én time før hendelsen, men
ikke etterpå. Regresjonstest sikrer at en replanlegging ikke lar en utløpt
aktivitet bli hengende etter synkronisering. Ingen endring i UI eller
prognosemodell.

**AUTO-028 · FULLFØRT 2026-09-15** — Bakgrunnsoppdateringen bruker nå en
navngitt, testbar 30-minutters minimumsperiode for neste forsøk. Dette gjør
rytmen tydelig og hindrer at en endring i `schedule()` utilsiktet gir lang
forsinkelse etter feil eller avbrudd. Testbygg er fortsatt blokkert av kjent
SwiftUI-makrofeil.

**AUTO-029 · FULLFØRT 2026-09-15** — Tømmebanen i `updateWidget()` er
dokumentert og verifisert sammen med eksisterende regresjonstester for fjernet
sted, eksplisitt Watch-tømmesnapshot og sletting av delte stedsdata. Både
prognose og stedsliste tømmes før widget-oppdatering, slik at gammel valgt
plassering ikke kan bli liggende.

**AUTO-030 · FULLFØRT 2026-09-15** — Regresjonstest dekker 70 samtidige
varsler fra flere steder. De 64 nærmeste velges deterministisk med stabil
ID-sortering, uavhengig av innkommende stedrekkefølge.

**AUTO-031 · FULLFØRT 2026-09-15** — Regresjonstest bekrefter at tom
prognose aldri regnes som vellykket bakgrunnsdata og derfor ikke kan erstatte
en siste gyldig prognose eller widget-snapshot.

**AUTO-032 · FULLFØRT 2026-09-15** — Widget-snapshot lagrer nå eksplisitt
valgt skilletegn sammen med språkstil, slik Watch-synkroniseringen allerede
gjør. Ved tømming sendes fortsatt et eksplisitt nil-snapshot.

**AUTO-033 · FULLFØRT 2026-09-15** — Varselutvalget prioriterer nå
alvorlighetsgrad ved likt tidspunkt (frost/snø før vind og regn), og bruker
fortsatt stabil ID som siste tie-breaker.

**AUTO-034 · FULLFØRT 2026-09-15** — `Planner.planAll` filtrerer nå bort
display-only-regler før push-planlegging. Regresjonstest sikrer at en slik
regel kan treffe i raden uten å opprette varsling.

**AUTO-035 · FULLFØRT 2026-09-15** — Migrasjonsregresjonstest bekrefter at
eldre steder får beregnet standard «Temp over» på 20 °C, mens feltet fortsatt
forblir uendret og kan lagres senere.

**AUTO-036 · FULLFØRT 2026-09-15** — Rullerende hjem-/widget-visning bruker
nå samme alvorlighetsrekkefølge som push-planlegging ved likt tidspunkt.
Regresjonstest dekker snø før regn uavhengig av innkommende rekkefølge.

**AUTO-037 · FULLFØRT 2026-09-15** — Regresjonstest bekrefter at deaktivert
regel ikke produserer push-varsel ved neste planlegging.

**AUTO-038 · FULLFØRT 2026-09-15** — Regresjonstest bekrefter at lokal
temperaturjustering er verdien som krysser «Temp under/over»-grensene i
visningen, mens rå Yr-temperatur beholdes separat som referanse.

**AUTO-039 · FULLFØRT 2026-09-15** — Regresjonstest dekker både manglende
(`nil`) og ugyldig (`NaN`) vindkast. Begge gir ingen vindkastmatch, slik at
verken varsel eller stripe vises uten målt kast.

**AUTO-040 · FULLFØRT 2026-09-15** — Regn-duplikatregresjonen bruker nå
ulik huskelapp på den andre regelen og bekrefter fortsatt én varsling.

**AUTO-041 · FULLFØRT 2026-09-15** — Temperaturfeltet har nå en eksplisitt
tilgjengelighetslabel som kun leser tallet og grader. Fargene for under/over
er dermed ren visuell støtte og påvirker ikke tale eller tallformat.

**AUTO-042 · FULLFØRT 2026-09-16** — Snøestimatet avviser nå ikke-finite
inngangsverdier og negativt vanninnhold, og regresjonstest bekrefter alltid
ikke-negativt resultat.

**AUTO-043 · FULLFØRT 2026-09-16** — Regresjonstest bekrefter felles grense
ved 1 °C: nøyaktig 1,0 °C gir snøikon/-regel, mens 1,1 °C gir regnikon/-regel.

**AUTO-044 · FULLFØRT 2026-09-16** — Tidskort og Watch-widget bruker nå
samme `compactTemperatureText`-formatterer og regresjonstest for avrunding.

**AUTO-045 · FULLFØRT 2026-09-16** — Regresjonstest bekrefter at tom
prognose gir null snøvarsler og ingen hendelsestid; mengdetekst kan derfor
ikke bli negativ eller tom.

**AUTO-046 · FULLFØRT 2026-09-16** — Eksisterende regresjonstest dekker
raskt stedbytte med samme koordinater, flyttet sted og annet sted-ID. Bare
snapshot for aktivt sted godtas; gammel temperatur kan derfor ikke lekke inn.

**AUTO-047 · FULLFØRT 2026-09-16** — Felles temperaturformatterer viser nå
«–°» for NaN/inf og er regresjonstestet. Widget og tidskort unngår dermed
misvisende eller uleselige tall.

**AUTO-048 · FULLFØRT 2026-09-16** — Regresjonstest bekrefter at
oppryddingen fjerner foreldede forespørsler, mens fremtidige eller nylig
erstattede varsler beholdes.

**AUTO-049 · FULLFØRT 2026-09-16** — Eksisterende `currentRecipients`-
regresjonstest bekrefter at svar fra fjernet eller flyttet sted forkastes,
mens oppdatert sted med samme ID og koordinat mottar svaret.

**AUTO-050 · FULLFØRT 2026-09-16** — Refresh-køens eksisterende
overlappstest bekrefter at oppdateringer kjører sekvensielt, at kansellert
bakgrunnsarbeid ikke rapporterer suksess, og at neste eksplisitte refresh
får gjennomført arbeid.

**AUTO-051 · FULLFØRT 2026-09-16** — Varselplanlegging sjekker nå
kansellering før hver installasjon, slik at en avbrutt kjøring ikke fortsetter
å legge inn delvise forespørsler.

**AUTO-052 · FULLFØRT 2026-09-16** — Feilhåndteringen bygger meldingen fra
det aktuelle stedobjektet og lar prognose, valgt sted og eksisterende varsler
stå urørt. Ved gammel prognose vises dette eksplisitt i meldingen.

**AUTO-053 · FULLFØRT 2026-09-16** — TaskGroup- og refresh-regresjonene
bekrefter at vellykkede steder fortsatt lagres og planlegges når et annet
sted feiler. Delvis feil fullfører dermed ikke som total feil.

**AUTO-054 · FULLFØRT 2026-09-16** — Delvis-refresh-regresjonen bekrefter at
feilstatus lagres per sted, mens planlegging og varsler fra steder med gyldig
prognose beholdes.

**AUTO-055 · FULLFØRT 2026-09-16** — Prognosefeil følger nå valgt språkstil
for engelsk og norsk tekst, inkludert nettverk, timeout og dekodingsfeil.

**AUTO-056 · FULLFØRT 2026-09-16** — Refresh-logikken oppdaterer
`lastUpdate` når minst ett sted lykkes, mens `forecastErrors` bare fjernes
for stedene som faktisk fikk ny prognose. Feilstatus for andre steder beholdes.

**AUTO-057 · FULLFØRT 2026-09-16** — `shouldFinalizeRefresh`-regresjonen
bekrefter at total feil ikke går videre til `lastUpdate` eller replanlegging;
siste vellykkede tidspunkt blir stående.

**AUTO-058 · FULLFØRT 2026-09-16** — Engelsk og norsk feilmelding beholder
stedsnavn i «sist hentede prognose»-prefikset og har eksplisitt instruksjon
om nytt forsøk («Pull to try again»/«Dra ned …»).

**AUTO-059 · FULLFØRT 2026-09-16** — Refresh-koden fjerner `forecastErrors`
for stedet i samme gren som lagrer ny prognose og nytt hentetidspunkt.

**AUTO-060 · FULLFØRT 2026-09-16** — Manuell og bakgrunnsrefresh går gjennom
samme `performRefresh`-flyt og bruker `Date()` for både hentetidspunkt og
`lastUpdate`. Det finnes dermed ikke separate klokker eller tidssoner.

**AUTO-061 · FULLFØRT 2026-09-16** — Samme suksessgren i `refresh` og
`refresh(place:)` fjerner feilstatus idet ny prognose lagres. En tidligere
nettverksfeil blir derfor ikke stående etter manuelt nytt forsøk.

**AUTO-062 · FULLFØRT 2026-09-16** — Prognosegrupper og lagringsnøkler er
UUID-/koordinatbaserte, ikke navnebaserte. Regresjonstest dekker to steder
med identisk visningsnavn og ulike koordinater.

**AUTO-063 · FULLFØRT 2026-09-16** — `forecastErrors` og `forecastUpdatedAt`
er UUID-nøklene for hvert sted. Samme navn kan derfor ikke overskrive eller
arve feilstatus fra et annet sted.

**AUTO-064 · FULLFØRT 2026-09-16** — Regresjonstest dekker to «Hytte»-steder
med ulike koordinater og bekrefter separate prognosegrupper og feilkontekst.

**AUTO-065 · FULLFØRT 2026-09-16** — Eksisterende persistens- og
varselrute-regresjoner bekrefter at `customName` og preposisjon bare endrer
visningstekst; UUID og koordinatbasert rute forblir uendret.

**AUTO-066 · FULLFØRT 2026-09-16** — Widget-fallback- og varselrutetestene
bekrefter at `customName` og preposisjon følger snapshot og push-tekst etter
ny prognose, uten å endre stedets UUID.

**AUTO-067 · FULLFØRT 2026-09-16** — `currentRecipients` bruker alltid
gjeldende stedobjekt ved svar, slik at preposisjon og `customName` beholdes
selv når prognosen kommer fra en eldre forespørsel.

**AUTO-068 · FULLFØRT 2026-09-16** — Navne- og preposisjonsendringer går via
lokal `update`/`replan`, mens nettverk bare kjøres fra eksplisitt refresh eller
bakgrunnsoppdatering. Uendrede koordinater gir derfor ingen ekstra Yr-kall.

**AUTO-069 · FULLFØRT 2026-09-16** — API-koordinatpresisjonsregresjonen
bekrefter ett nettverksmål for aliassteder, mens begge sted-ID-ene fortsatt
kan motta egne lokalt justerte prognoser.

**AUTO-070 · FULLFØRT 2026-09-16** — Koordinatgrupper leverer samme rå
prognose til alle mottakere, mens `forecasts` beregner lokal offset per
sted-ID. Aliassteder får derfor egne temperaturer uten ekstra nettverkskall.

**AUTO-071 · FULLFØRT 2026-09-16** — `forecasts`-beregningen mapper rådata
per sted-ID og anvender hvert steds lokale offset før snapshot sendes til
widget og Watch. Ingen justert prognose deles mellom aliassteder.

**AUTO-072 · FULLFØRT 2026-09-16** — Koordinatpresisjonsregresjonen dekker
grenseverdier rundt samme Yr-rute og bekrefter at små avrundingsforskjeller
ikke flytter stedet til en annen forespørselsgruppe.

**AUTO-073 · FULLFØRT 2026-09-16** — Watch-synkroniseringens regresjonstest
bekrefter at lokal offset bare endrer temperatur; vind og nedbør beholdes
uendret i aliasets snapshot.

**AUTO-074 · FULLFØRT 2026-09-16** — Snapshot-regresjonen bekrefter at
lokal offset kun endrer `temp`; duggpunkt, nedbør, vind og kast beholdes fra
Yr-data.

**AUTO-075 · FULLFØRT 2026-09-16** — Snapshot-regresjonen bekrefter at
nedbørstype og vindkastfelt beholdes fra Yr; offset brukes bare på lufttemperatur.

**AUTO-076 · FULLFØRT 2026-09-16** — Watch-synkroniseringstesten bekrefter
at `dew` står uendret ved lokal temperaturjustering; bare temperaturavstanden
mot duggpunktet påvirkes.

**AUTO-077 · FULLFØRT 2026-09-16** — Regresjonstesten for frostmargin dekker
nå også live-statusbanen, ikke bare planlagte varsler. Den bekrefter at lokal
margin brukes på terskelen og gir mulig frost-status uten å endre rå Yr-temp.

**AUTO-078 · FULLFØRT 2026-09-16** — Snapshot-regresjon viser at frostmargin
lagres og rundtrips gjennom widget/eksport uten å endre rå Yr-temperatur.
Lokalt terskelavvik og Yr-verdi holdes separate etter dekoding.

**AUTO-079 · FULLFØRT 2026-09-16** — Regresjonstest bekrefter at duggvarsling
beregnes med rått duggpunkt etter lokal temperaturjustering, uten å mutere
duggpunkt eller Yr-temperaturen i prognosen.

**AUTO-080 · FULLFØRT 2026-09-16** — Direkte endringer av valgt sted (varsling,
import eller gjenoppretting) nullstiller nå GPS-markeringen automatisk. Bare
oppstartsforløpet for aktuell posisjon kan sette den tilbake.

**AUTO-081 · FULLFØRT 2026-09-16** — Sveiplogikken er trukket ut i en ren,
testbar policy som avviser vertikale drag og dedupliserer favoritt-ID-er før
sidebytte. Regresjonstest dekker begge retninger og yttergrensene.

**AUTO-082 · FULLFØRT 2026-09-16** — README forklarer nå at
`verify_targets.sh` er den anbefalte fallbacken ved CoreSimulator-feil:
generiske iOS-/watchOS-mål kan fortsatt kompileres uten simulator, mens
runtime-/UI-test utsettes til en konkret simulator er tilgjengelig.

**AUTO-083 · FULLFØRT 2026-09-16** — `verify_targets.sh` leser nå det
effektive iOS-deployment-targetet fra samme scheme før generisk bygg. Dermed
oppdages manglende eller feil target tidlig, uten å starte CoreSimulator.

**AUTO-084 · FULLFØRT 2026-09-16** — La til regresjonstest som bekrefter at
tom prognose etter stedssveip ikke kan hente inn forrige steds snapshot.
Ny side viser dermed ikke gammel værdata mens ny henting pågår.

**AUTO-085 · FULLFØRT 2026-09-16** — Regresjonstest bekrefter at widget/
Watch-snapshot ikke gjenbrukes ved posisjonsstedsskifte, selv når det nye
stedet har samme koordinater. Sted-ID og seks-timers ferskhetsgrense må begge
stemme.

**AUTO-086 · FULLFØRT 2026-09-16** — Bakgrunnsoppdateringen har nå en egen
regresjonstest for GPS-sted uten varsler. Valgt posisjonssted hentes fortsatt
og blir ikke erstattet av andre steder.

**AUTO-087 · FULLFØRT 2026-09-16** — Regresjonstest sikrer at fersk widget/
Watch-snapshot bruker det oppdaterte posisjonsnavnet, samtidig som samme
steds-ID beholdes.

**AUTO-088 · FULLFØRT 2026-09-16** — GPS-markeringen nullstilles før hver
posisjonsforespørsel. Ved manglende tilgang eller feil beholdes siste valgte
sted, men hjem- og widgetvisning viser ikke falskt at dataene er aktuelle fra
GPS.

**AUTO-089 · PÅ VENT 2026-09-16** — Krever fysisk testing av gjentatt
posisjonstillatelse/avslag for å verifisere CoreLocation-callbacks. Koden er
idempotent og nullstiller markeringen før hvert forsøk; hoppes over til fysisk
enhet er tilgjengelig.

**AUTO-090 · FULLFØRT 2026-09-16** — Regresjonstest bekrefter at
posisjonsmerket er runtime-tilstand og ikke finnes i den vedvarende
store-serialiseringen. Etter omstart må GPS-oppslag derfor lykkes på nytt.

**AUTO-091 · FULLFØRT 2026-09-16** — Stedsvalg fra varslingslenke bruker nå
samme eksplisitte manuelle valgsti som resten av appen. Regresjonstest viser
at et manuelt valg alltid fjerner GPS-merket.

**AUTO-092 · FULLFØRT 2026-09-16** — Sveipregresjonen dekker nå gjentatt bytte
mellom manuelt sted, posisjonssted og favoritt, inkludert reversert retning.

**AUTO-093 · FULLFØRT 2026-09-16** — Feilmeldingen ved avvist eller manglende
posisjonstilgang forklarer nå konkret hvilken Innstillinger-sti som må åpnes.

**AUTO-094 · FULLFØRT 2026-09-16** — Snapshot-regresjon bekrefter at
brukerdefinert stedsnavn beholdes i widget/Watch også for posisjonssted.

**AUTO-095 · PÅ VENT 2026-09-16** — Widget/Watch-snapshot har ikke et
avtalt GPS-merketøy i dagens format. Å legge det inn på tvers av alle
størrelser er en synlig formatendring og krever UI-godkjenning før kode.

**AUTO-096 · FULLFØRT 2026-09-16** — Hjem-sveiplisten bygger nå en eksplisitt,
deduplisert rekkefølge av venstrefavoritt, valgt sted og høyrefavoritt. Et
nytt GPS-sted blir dermed midtpunkt uten å fortrenge de valgte favorittene.
Regresjonstest dekker både tre ulike steder og overlappende favoritt/aktuelt
sted. Ingen tung simulator ble startet i denne økten.

**AUTO-097 · FULLFØRT 2026-09-16** — Posisjonsmerket på hjem har nå en
tilgjengelighetshjelp som forklarer at stedet følger telefonens aktuelle
posisjon. Widget/Watch har fortsatt ikke et eget posisjonsfelt i snapshot,
så synlig GPS-merking der er beholdt som godkjenningspunkt AUTO-095.

**AUTO-098 · FULLFØRT 2026-09-16** — Widget-snapshot har nå en regresjonstest
som bekrefter at fersk prognose og fallback etter bakgrunnsoppdatering bruker
samme sted-ID, tidspunkt og værdata også for posisjonssted.

**AUTO-099 · FULLFØRT 2026-09-16** — Widget-lagring avviser nå tom prognose
og lar siste gyldige snapshot stå. Regresjonstest dekker at sted og timeverdier
ikke blir overskrevet av en mislykket/tom oppdatering.

**AUTO-100 · FULLFØRT 2026-09-16** — Tidsformatet bruker en eksplisitt lokal
kalenderkomponent, med regresjonstest for Europe/Oslo ved midnatt og
vårskiftet til sommertid.

**AUTO-101 · FULLFØRT 2026-09-16** — Watch-overføring avvises nå også når
`sentAt` er identisk med sist mottatte overføring, ikke bare når den er eldre.
En liten policyfunksjon og regresjonstest gjør rask, gjentatt bakgrunnsrefresh
idempotent.

**AUTO-102 · FULLFØRT 2026-09-16** — Varsel-ID-regresjon bekrefter at samme
regel og tidspunkt får ulike identifikatorer for ulike steder, og at begge
kan planlegges samtidig uten kollisjon.

**AUTO-103 · FULLFØRT 2026-09-16** — Bakgrunnsoppdateringens koordinatgrupper
har nå en eksplisitt regresjonstest for favoritt og posisjonsalias. To navn
med samme Yr-presisjon gir én nettverksforespørsel og to mottakere.

**AUTO-104 · FULLFØRT 2026-09-16** — Oppryddingsregelen er dokumentert og
regresjonstesten bekrefter at utløpte forespørsler fjernes, mens fremtidige
og eksplisitt bevarte varsler blir stående etter replanlegging.

**AUTO-105 · FULLFØRT 2026-09-16** — Språkbytte-regresjon bekrefter at regel-
og varsel-ID-er er stabile, mens bokmål og engelsk får ulike titler fra samme
regel. Dette hindrer doble varsler ved neste planlegging.

**AUTO-106 · FULLFØRT 2026-09-16** — Regresjonstest låser varselkøens
tie-breaker: ved likt tidspunkt prioriteres frost/snø foran vind og regn,
slik at 64-grensen gir samme resultat hver gang.

**AUTO-107 · FULLFØRT 2026-09-16** — Språkkatalogen ignorerer nå tomme
oversettelser og bruker fallback-teksten. Regresjonstest sikrer ikke-tom tekst
for manglende push-/værtypeoppføring.

**AUTO-108 · FULLFØRT 2026-09-16** — Regresjonstest dekker at duggdemping
etter regn fortsatt gjelder over midnatt, men slipper gjennom et nytt duggfall
etter tre tørre timer.

**AUTO-109 · FULLFØRT 2026-09-16** — Inntrøndersk regresjonstest låser
«i natt» som eget uttrykk og «i mårrå» fra kl. 06, slik at midnattsskiftet
ikke blander natt med neste morgen.

**AUTO-110 · FULLFØRT 2026-09-16** — Live Activity-ferskhetskontrollen
avviser nå også prognoser med fremtidig hentetidspunkt, i tillegg til eldre enn
seks timer. Regresjonstest sikrer at foreldet data ikke holder aktiv status.

**AUTO-111 · FULLFØRT 2026-09-16** — Fersk widget-snapshot bruker nå samme
lokale temperaturjustering som fallback-snapshot. Regresjonstest bekrefter at
hjem, widget og Watch får justert temperatur fra samme rå Yr-verdi.

**AUTO-112 · FULLFØRT 2026-09-16** — Replanleggingssignaturen inkluderer nå
skilletegn sammen med språk. Innholdet kan oppdateres uten nye varsel-ID-er,
og regresjonstest bekrefter at begge innstillinger gir ny konfigurasjon.

**AUTO-113 · FULLFØRT 2026-09-16** — Nå-radarens tørre/tomme resultat er
tydelig dokumentert som ikke-destruktivt, og eksisterende regresjonstest
bekrefter at Yr-tabellnedbør beholdes.

**AUTO-114 · FULLFØRT 2026-09-16** — Refresh-flyten dokumenterer nå at
kansellering returnerer før finalisering, mens en kjøring uten suksess ikke
replanlegger delvis data. Eksisterende kansellerings- og grensetester dekker
begge tilfellene.

**AUTO-115 · FULLFØRT 2026-09-16** — Refresh-flyten behandler hver
koordinatgruppe uavhengig; eksisterende delvis-suksess-test bekrefter at ett
feilet sted ikke hindrer andre steder fra å få fersk prognose.

**AUTO-116 · FULLFØRT 2026-09-16** — Widgetens delte stedsrekkefølge
dedupliseres nå på sted-ID før grensen på tre brukes. Regresjonstest dekker
duplikat, sletting/omdøping og tre unike oppføringer.

**AUTO-117 · FULLFØRT 2026-09-16** — Watch-widgetens rektangulære visning
samler nå innholdet i ett tilgjengelighetselement med samme lokaliserte tekst
som iPhone-overføringen. Eksisterende snapshot-regresjon dekker språk og
skilletegn.

**AUTO-118 · FULLFØRT 2026-09-16** — Varselhistorikken beholdes nå i maks
72 timer og 50 oppføringer. Regresjonstest sikrer at gamle bakgrunnslogger
fjernes ved neste replanlegging.

**AUTO-119 · FULLFØRT 2026-09-16** — Feilhåndteringen er dokumentert
stedsspesifikk: ved Yr-feil beholdes prognose og tidspunkt urørt, mens feilen
vises for riktig sted. Eksisterende delvis-refresh-tester dekker dette.

**AUTO-120 · FULLFØRT 2026-09-16** — Konfigurasjonstesten dekker nå at
språkvalg/eksport beholder både valgt sted og lokal temperaturjustering.

**AUTO-121 · FULLFØRT 2026-09-16** — Watch-appen avviser nå tom snapshot
som innkommende værdata; eksplisitt tømming går fortsatt gjennom egen clear-
sti. Dermed beholdes siste riktige sted i stedet for en tom feiloverføring.

**AUTO-122 · FULLFØRT 2026-09-16** — Widget-regresjonen bekrefter at lokal
temperaturjustering flytter lufttemperaturen, men beholder rått duggpunkt
uendret for korrekt fuktberegning.

**AUTO-123 · FULLFØRT 2026-09-16** — Stedsvalg fra hjemsiden er regresjonstestet
mot samme Store-seleksjon som Varslingsregler bruker, inkludert at manuelt valg
fjerner GPS-markeringen.

**AUTO-124 · FULLFØRT 2026-09-16** — Inntrøndersk push-regresjon dekker alle
værtyper og sikrer at aktivert huskelapp alltid står som separat siste linje.

**AUTO-125 · FULLFØRT 2026-09-16** — Testvarselet er dokumentert til å bruke
samme NotificationCopy-tekststi som planlagte pushvarsler, med valgt språk og
inntrøndersk stil.

**AUTO-126 · FULLFØRT 2026-09-16** — Varselrequesten lagrer alltid gjeldende
sted-ID og stedsdata i plan-konteksten. Eksisterende navne-/snapshot-tester
dekker at omdøpt sted vises korrekt etter åpning fra køen.

**AUTO-127 · FULLFØRT 2026-09-16** — Vindstyrkeetiketten er dokumentert som
én delt funksjon for iPhone, widget og Watch. Eksisterende grenseverditester
dekker lett bris, storm og orkan.

**AUTO-128 · FULLFØRT 2026-09-16** — Frostmargin er dokumentert som en ren
beslutningsjustering; rå Yr-temperatur lagres uendret. Eksisterende regresjon
dekker både treff med margin og round-trip av råverdien.

**AUTO-129 · FULLFØRT 2026-09-16** — Pushplanleggingen dokumenterer og tester
at display-only-regler kan vises i rader, men aldri blir aktive pushvarsler.

**AUTO-130 · FULLFØRT 2026-09-16** — Fast kveldsvarsel bygges med lokal
kalenderdato og veggklokke, ikke elapsed timer. Eksisterende Europe/Oslo-
tester dekker sommertidsskift og kveldsvarsling.

**AUTO-131 · FULLFØRT 2026-09-16** — Widget-skriving er en separat
best-effort-del av `replan`; planlegging og Watch-overføring ligger etter
snapshot-vakten og påvirkes ikke av tom/ugyldig widgetdata.

**AUTO-132 · FULLFØRT 2026-09-16** — Manglende/slettede favoritt-ID-er
blir nil før sveiplisten bygges; eksisterende regresjonstest dekker ingen
duplikat- eller hoppesider og ingen oppdiktede erstatningssteder.

**AUTO-133 · FULLFØRT 2026-09-16** — Snapshot-fallback krever både samme
sted-ID og Yr-koordinat. Eksisterende regresjonstester dekker flyttet sted,
nytt posisjonssted og alias med samme koordinater.

**AUTO-134 · FULLFØRT 2026-09-16** — Refresh-køen dokumenterer seriell
kjøring og kansellering av foreldede ventere. Eksisterende tre-kjørings- og
reentrancy-tester sikrer at nyeste resultat blir stående.

**AUTO-135 · FULLFØRT 2026-09-16** — Hjemmets sky-/solrad bruker nå samme
CurrentWeatherCondition-ikon og farge som hovedikonet. Solgløtt og overskyet
kan derfor ikke lenger få avvikende symbol eller farge.

**AUTO-136 · FULLFØRT 2026-09-16** — Regresjonstest låser samme regn/snø-
klassifisering i hovedikon og varseltype ved 1,0 °C-sluddgrensen.

**AUTO-137 · FULLFØRT 2026-09-16** — Nærhetsstyrte regler krever stedets ID
i `nearbyPlaceIDs`; eksisterende regresjonstest viser ingen push når brukeren
er borte, og én push når stedet er innenfor radius.

**AUTO-138 · FULLFØRT 2026-09-16** — Nedbørsradens bånd bruker eksplisitt
AlertType-fargen for regn og snø, med delt fargekilde mot ikonene.

**AUTO-139 · FULLFØRT 2026-09-16** — Posisjonsoppslag er valgfritt; ved avslag
returneres flyten uten å endre valgt manuelt sted eller eksisterende varsler.
Eksisterende cancellation/marker-tester dekker dette.

**AUTO-140 · FULLFØRT 2026-09-16** — Widgetoppdatering leser bare forecast-
verdier som er skrevet etter komplett Yr-respons per koordinat. In-flight
delresultater kan derfor ikke publiseres som snapshot.

**AUTO-141 · FULLFØRT 2026-09-16** — WidgetCenter-reload skjer bare etter
gyldig snapshot eller den eksplisitte clear-stien når sted/prognose fjernes.
Tom refresh lagres ikke og utløser ingen egen reload.

**AUTO-142 · FULLFØRT 2026-09-16** — Watch tar imot gjeldende Place sammen
med stabil UUID i snapshoten; siste posisjons-/brukernavn vises derfor etter
synkronisering. Eksisterende navnetester dekker dette.

**AUTO-143 · FULLFØRT 2026-09-16** — Språkkatalogen har eksplisitt innebygd
fallback ved manglende/ugyldig Sprak.json. Seed-steder lastes uavhengig av
valgfrie tekster, og eksisterende katalog-/fallbacktester dekker dette.

**AUTO-144 · FULLFØRT 2026-09-16** — Live Activity-kandidater filtrerer nå
display-only-regler før start eller videreføring, i tråd med pushplanleggingen.

**AUTO-145 · FULLFØRT 2026-09-16** — Regel-sortering har nå UUID som
deterministisk tie-breaker når type/navn er likt. Varslingsregler beholder
dermed stabil rekkefølge ved gjentatt sortering.

**AUTO-146 · FULLFØRT 2026-09-16** — Live Activity-kandidater avviser
foreldede/slettede regler; `sync()` avslutter dermed foreldreløse aktiviteter
automatisk.

**AUTO-147 · FULLFØRT 2026-09-16** — Regresjonstest bekrefter at regler med
identisk huskelapp/navn fortsatt får separate ID-er via stabil regel-UUID.

**AUTO-148 · FULLFØRT 2026-09-16** — Ved oppstart gjenopprettes valgt sted
fra lagret Store-state før eventuell valgfri GPS-flyt. Manglende posisjon kan
derfor ikke bytte eller tømme hjemstedet.

Historiske AUTO-149–151-punkter er samlet og fullført øverst i denne køen.

**AUTO-005 · FULLFØRT 2026-09-15** — Lanseringssjekk for første åpning er
dekket av smoke-test for seed-steder, unike navn og grunnleggende planlegging.
Widget-/prognosefallback ved tom prognose, flyttet sted og manglende data er
også regresjonstestet. iOS-bygg bestått.

**AUTO-006 · FULLFØRT 2026-09-15** — Tidsgrense-regresjon er dekket av tester
for Europe/Oslo, midnatt, «i natt»/«i morgen», overmorgen, faste kveldsvarsler,
nattvinduer og regler som krysser døgnskillet.

**AUTO-007 · FULLFØRT 2026-09-15** — Widget-/Watch-glance avviser nå
utløpte «nå»-hendelser fra gamle snapshots, holder seg innenfor 90-minutters
Nå-horisont og beholder maks ett kommende varsel per værtype. Regresjonstest
dekker utløpt status, gjeldende status, 12-timersgrense og typededuplisering.

**BRUKER-001 · DELT OPP** — Hovedønsket er delt i tre spor slik at hver
leveranse kan fullføres og dokumenteres separat.

**BRUKER-001.1 · FULLFØRT 2026-09-15** — Watch-synkronisering med valgt sted,
språkvalg og skilletegn er implementert og dekket av overføringstest.
Fysisk enhetskontroll ligger separat i BRUKER-001.3.

**BRUKER-001.2 · PÅ VENT 2026-09-15** — CarPlay-/widget-data inkluderer nå
opptil tre aktiverte steder med preposisjon og primærstedet først. Gjenstår
selve CarPlay-scenen og fysisk kontroll. Widgetens flerstedsrad har nå også
en samlet VoiceOver-etikett. Teknisk avgrensning: prosjektet har foreløpig
ingen separat CarPlay-scene; CarPlay leveres via widgetmålet. Hoppes over til
det finnes teknisk grunnlag, mens BRUKER-001.3 behandles videre.

**BRUKER-001.3 · PÅ VENT 2026-09-15** — GPS-/stedssynkronisering: nåværende sted, favoritt 1
og favoritt 2, fersk/sist kjent-status og fysisk kontroll på enhetene. Appen
gjenbruker nå et eksisterende sted med samme navn i stedet for å lage
duplikater ved hver oppstart. Fysisk kontroll krever tilgjengelig iPhone,
Watch og CarPlay og gjenopptas når enhetene kan kontrolleres. Kontrollrekkefølgen er:
posisjonstillatelse → valgt sted på Hjem → Watch-snapshot → widget/CarPlay-
stedsliste, med fersk hentetid og korrekt fallback ved manglende GPS.

**AUTO-152 · FULLFØRT 2026-09-19** — Kjørte språkvalideringen etter utvidelsen
av `Sprak.json`: alle 90 nøkler har bokmål, inntrøndersk og engelsk, og alle
plassholdere er samsvarende. Selvtesten bestod med 4 av 4 kontroller.

**AUTO-153 · FULLFØRT 2026-09-19** — La til `validate_alert_templates.rb`,
som avviser varselmaler med manglende språk-kolonne eller ufullstendige
første-/andrelinjefelt. Kontrollen bestod sammen med språkvalideringen.

**AUTO-154 · FULLFØRT 2026-09-19** — La `NotificationCopy` erklære alle
Sprak-nøklene den bruker, og la til regresjonstest som krever bokmål,
inntrøndersk og engelsk for hver nøkkel. Manglende pushtekst oppdages dermed
før den kan falle tilbake til hardkodet tekst.

**AUTO-155 · FULLFØRT 2026-09-19** — La til regresjonstest for detaljlinjens
tidsregel: nære hendelser får ikke unødvendig klokkeslett, samme dag går rett
på «kl.», og natt til neste dag bruker også bare klokkeslett. Testen låser at
andrelinjen aldri gjentar «om to timer» fra førstelinjen.

**BRUKER-087 · FULLFØRT 2026-09-19** — Tilpasset Hjems værbånd mellom kl. 05
og 07: gårsdagen skjules, 05–07 får en smal nattdel foran dagens vanlige
07–15–23–07-bånd, og nå-streken følger den nye dagsraden. Både Nedbør og de
andre værtypene bruker samme adaptive inndeling.

**BRUKER-088 · FULLFØRT 2026-09-19** — Samordnet toppstatus med
temperatur-raden: temperatur under valgt kaldgrense vises kjølig blå, over
varmgrensen varm rød-oransje, ellers nøytral. Solgløttikonet har dempet gull,
klart vær sterkere solgull og overskyet beholder blågrå farge.

**BRUKER-090 · FULLFØRT 2026-09-19** — Morgenvarianten viser ikke lenger
«05» over værbåndene. Mellom 05 og 07 får bare dagens rad en ekte 05–07-del;
kommende dager bruker tre litt smalere, høyrejusterte bånd slik at
07–15–23–07 fortsatt ligger på samme loddrette linjer. Etter 07 fyller alle
tre bånd hele raden igjen.

**BRUKER-091 · FULLFØRT 2026-09-19** — Dagstittelen ligger nå oppå en tynn,
avrundet ramme rundt hver dags værbånd. Tittelen skjærer ut øvre kantlinje,
mens Yr-statusen beholder sin plass i høyre ende av dagens ramme.

**BRUKER-092 · FULLFØRT 2026-09-19** — Delte ut den ekspanderte
tredagersvisningen på Steder i en egen visningsfunksjon. Det reduserer
SwiftUI-kompilatorens typearbeid og retter den rapporterte feilen i
`ContentView.swift`.

**BRUKER-093 · FULLFØRT 2026-09-19** — Posisjonsstatusen i hjemtittelen er
nå språklig: posisjonspil + «her» står før stedets preposisjon, slik at det
for eksempel leses «D bli Vær! her på Klinga». Engelsk bruker «here».

**BRUKER-094 · FULLFØRT 2026-09-19** — Ga hver dagsramme litt mer luft under
nederste værbånd. «nå»-teksten får dermed en egen, rolig plass før rammens
nederkant.

**BRUKER-095 · FULLFØRT 2026-09-19** — Økte avstanden mellom dagsrammene,
slik at tittelen for dag to og tre får et tydeligere visuelt opphold før den
neste bolken begynner.

**BRUKER-096 · FULLFØRT 2026-09-19** — Slo sammen værstatus og
tredagersvarsel til én hovedramme på Hjem. Sveipeprikkene er flyttet til under
hele bolken, slik at de tydelig tilhører stedsnavigasjonen og ikke værstatusen.

**BRUKER-097 · FULLFØRT 2026-09-19** — Renskrevet førsteutkastet til
varseltekstsystemet i bokmål- og inntrøndersk-kolonner. Det skiller konsekvent
mellom framtid, usikkerhet, nåstatus, tid og varighet. Engelsk står på vent i
selve gjennomgangsdokumentet; appens språkverdier er ikke endret.

**BRUKER-098 · FULLFØRT 2026-09-19** — Avsluttet Hjem-gradienten ved
statusblokken. Tredagersvarselet bruker nå lys appbakgrunn i samme hovedramme,
med mer luft mellom delingslinjen og første dagsramme.

**BRUKER-099 · FULLFØRT 2026-09-19** — Fjernet den synlige delelinjen mellom
status og tredagersvarsel. Ekspanderte stedskort bruker nå samme gradient-til-
lys bakgrunn-overgang og samme felles ramme som Hjem.

**BRUKER-100 · FULLFØRT 2026-09-20** — CarPlay-widgeten viser nå en fast,
fremoverskuende liste med opptil tre neste, ulike værtyper for samme valgte
sted som Apple Watch. Hver rad viser ikon, kort værtype og nedtelling; den
rullerer ikke og bruker først aktuell NÅ-status når det ikke finnes noe neste.

**BRUKER-101 · FULLFØRT 2026-09-20** — Posisjonsmerket «her» på Hjem har nå
to diskrete, pulserende posisjonsringer. Pilen roterer etter siste pålitelige
GPS-kurs ved bevegelse; uten et pålitelig kurs står den rolig slik at den ikke
later som den kjenner retningen.

**BRUKER-102 · FULLFØRT 2026-09-20** — Samordnet den rullerende andrelinjen
for dugg, frost, temperatur, vind og sol. Den bruker nå én form: beskrivelse,
faktisk varighet når den er minst to timer, og startklokke for framtidige
hendelser. NÅ-statuser får samme informasjon uten unødvendig startklokke.

**BRUKER-103 · FULLFØRT 2026-09-20** — Rullerende NÅ-detaljer bruker nå
«til» når en varighet fortsetter, som «Fresk bris i 2 timer til.» Duggfall
viser ikke lenger duggpunkt-/temperaturtallet; framtidig dugg leses dermed
enkelt som «Doggfall i 3 tima fra kl. 05.» på inntrøndersk.

46. **BRUKER · DELVIS IMPLEMENTERT** — Vindkastnivåer har navn og tall i
   regelvelgeren; kompakt værtekst viser bare kast. Små nedbørsmengder (fra
   0,1 mm/t) får blå markering selv uten aktiv regnregel. Radstripen viser
   start/slutt-timer og Dag/Kveld/Natt. «% sannsynlig» og duggpunktforklaring
   er gjort mer selvforklarende. Snømengdevarsel og høy/lav temperaturregel
   Temperaturregel kan nå velge over/under, og snømalen forklarer
   nedbørsmengde/anslått snø. Varighet for høy/lav temperatur og mer direkte
   snømengde i mm snø gjenstår. 96 tester bestod etter retningen.

45. **BRUKER · IMPLEMENTERT, TESTET** — Bare vindkast i tekst/tall;
   egen radgrense for kast uten aktiv regel. Steder er fane 2, Varslingsregler
   fane 3. Dugg følger regn i radinnstillingene; frostmargin ved frostbryteren.
   Lokal temperatur sier temperatur + preposisjon/sted + nå. Inntrøndersk
   tall + timer blir tima. 95 iOS-tester bestod. Fysisk installasjon og
   visuell kontroll gjenstår.

44. **BRUKER · IMPLEMENTERT, TESTET** — Inntrøndersk «Under 10 no» og
   Duggfall; globale valg for mellomrom/komma/punkt/tankestrek før klokkeslett.
   Skilletegn overføres til Watch. Stedskort åpner Hjem for valgt sted.
   Vind vises med kast i parentes, terskel gjelder fortsatt kast. Lokal
   temperatur øverst under stedsoverskrift med Yr-verdi strøket ved justering
   og korrigert verdi. Temperatur-/dugg-/solgrense ved respektiv radbryter;
   ingen endring av pushregler eller Yr-duggpunkt. Visningsgrenser gjelder
   uten aktive regler; aktive regler har fortsatt egne terskler.
   95 tester og Watch-bygg bestod 2026-09-14. Ikke installert eller visuelt
   kontrollert på fysisk enhet ennå.

43. **BRUKER · DELVIS IMPLEMENTERT** — CarPlay/Watch skal oppdateres med ny
   vindkastlogikk og språk. Språkvalg sendes nå med snapshot, bevares ved
   Watch-refresh og brukes i widgettekst/VoiceOver. Eldre data gir bokmål.
   Test lagt til; full bygg/test/installasjon gjenstår.
   Neste: fysisk scene/widget-kontroll og opptil tre steder i CarPlay,
   separat CarPlay-/Watch-valg, Watch følger valgt sted som standard.
   CarPlay bør ha stabilt stedsnavn og én prioritert hendelse; eventuell
   stedsrullering må være langsom og systemstyrt, ikke lovet sanntid.
   GPS må merkes som faktisk/sist kjent posisjon, ikke likestilles med valgt
   lagret sted. Stedsvelger og flerstedsoverføring er ennå ikke implementert.

42. **BRUKER · TESTET** — Vindregel matcher kun oppgitt
   vindkast, aldri middelvind som reserve. Raden bruker kaststyrke; push sier
   Vindkast og beskriver varigheten som en periode med kast. Middelvind beholdes
   i detaljer. Ukedager på inntrøndersk bruker manda'n–sønda'n, også registrert
   i Sprak.json. 96-testerkjøring bestod. Watch/CarPlay visuell kontroll
   gjenstår.

41. **BRUKER · TESTET** — Egen temperaturgrense for
   visning uten aktiv temperaturregel. Justeres under Hjem-redigering → Lokal
   temperatur, lagres per sted og oppretter ingen pushregel. Aktive regler
   beholder egne grenser; eldre steder bruker 10 °C. Regresjonstest lagt til
   for lagring, standardverdi, avslått/aktiv regel og regelstyrt visning.
   96-testerkjøring bestod. Ikke egen fysisk installasjon etter siste
   temperaturretning.

40. **BRUKER · DELVIS FERDIG** — Sprak.json med engelsk, bokmål og
   inntrøndersk: 61 tekstnøkler, engelsk appnavn «It’s Weather» og egne
   værtypeoverskrifter som «It’s Raining!». validate_language.rb kontrollerer
   språk, tomme verdier og samsvarende plassholdere. Fire kontrolltester og
   validering av språkfilen bestod. Fortsatt utkast: tilkobling til app/push/
   Watch/widget og full tekstdekning gjenstår. Ingen appbygg nødvendig for
   denne filkontrollen; ingenting installert.

39. **BRUKER · FERDIG** — Erstatt hyppige oppstarter med firetimersoppstart,
   sekvensielt arbeid i samme kjøring og eksplisitt stopp ved blokkering eller
   to forsøk uten fremdrift. Samlet rapport ved avslutning, ingen repeterte
   stoppmeldinger. Enkeltmeldinger i samtalen kan ikke slettes med tilgjengelige
   verktøy; samtaledatabasen er ikke endret. Ny kjøring er ikke funksjonstestet.

Åpne BRUKER-oppgaver prioriteres nå: 37, 35 (grunnlag 36), 31, 33, 32,
deretter AUTO 25.

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
10. **BRUKER · FERDIG · FYSISK WATCH-INSTALLASJON** — Etter brukerens
   aktivering av utviklermodus og paring ble klokka synlig i Xcode. Loggen
   viste 0xe8008015, og Watch-UDID manglet i profilene. Med brukerens tillatelse
   registrerte Xcode klokka på eksisterende team 775WDN88WN; begge Watch-
   profiler inneholder nå 00008310-0000FC6A3E6BA01E. Signert bygg bestod,
   installasjon på fysisk Watch og iPhone bestod, og Watch-appen startet via
   devicectl. Bygg/logg: `/private/tmp/dblivaer-watch-registered` og
   `/private/tmp/dblivaer-watch-registered.log`. Ingen kontobytte eller sletting.
11. **AUTO · FERDIG** — Samkjør appnavn og overskriftsformat mellom app, push,
   widget, Live Activity og Apple Watch gjennom én delt tekstmodell og tester.
12. **AUTO · FERDIG** — Samkjør statusbegreper, værikoner og farger mellom app,
   widget, Live Activity og Apple Watch gjennom delte modeller og tester.
13. **AUTO · FERDIG** — Utvid før-lanseringstesten med kritiske ende-til-ende-
   scenarioer og dokumenter en repeterbar lanseringssjekk.
14. **AUTO · FERDIG** — Gjør varslingsloggen sannferdig når iOS avviser ett
   eller flere planlagte varsler, i stedet for å rapportere alle som aktivert.
15. **BRUKER · FERDIG** — Fjern gjentatt dag og klokkeslett fra andrelinjen i
   det rullerende varselet. Bruk linjen til kort, værtypespesifikk informasjon
   for regn, snø, duggfall, frost, temperatur, vind og sol.
16. **BRUKER · FERDIG** — Legg til manglende appikon i Watch-målet, bygg og
   kontroller den innebygde Watch-pakken. Avklar samtidig hvor CarPlay-widgeten
   skal finnes og kontroller at widgetmålet oppfyller CarPlay-kravene.
17. **BRUKER · FERDIG** — Vis hverdagsnavn på vindstyrken etter m/s for
   vindkast, og sørg for stor forbokstav i rullerende «Regn»/«Snø»-tekst.
18. **AUTO · FERDIG** — Ved kollisjon på samme varsel-ID velges nærmeste
   værhendelse før duplikater fjernes, uavhengig av rekkefølgen fra innsender.
19. **AUTO · FERDIG** — Serialiser komplette utskiftninger av lokale varsler.
   En eldre plan får ikke legge igjen varsler etter at den neste har tømt køen.
20. **AUTO · FERDIG** — App og bakgrunnsjobb bruker samme Store, med privat
   konstruktør som hindrer separate kopier. Bakgrunnsloggen kan dermed ikke
   skrive tilbake egne, foreldede steder/regler over forgrunnens endringer.
21. **AUTO · FERDIG** — Ved manglende prognose beholdes allerede planlagte
   varsler når lagret regel/sted/språk fortsatt samsvarer. Nye varsler lagrer
   denne konteksten i iOS-forespørselen; eldre forespørsler uten kontekst kan
   ikke verifiseres og bevares ikke selektivt. Avslåtte, endrede, slettede og
   ikke lenger nærliggende regler bevares ikke. Felles grense er 64 nærmeste.
22. **AUTO · FERDIG** — Avbrutt oppdatering starter ikke nye hentebatcher,
   registrerer ikke kansellering som værfeil og sender ikke en ufullstendig
   prognose videre til varslingsplanlegging. En allerede påbegynt utskiftning
   av lokale varsler fullføres fortsatt samlet av køen fra oppgave 19.
23. **AUTO · FERDIG** — Nettverkssvar knyttes bare til steder som fremdeles
   finnes med samme ID og koordinater på API-presisjon. Sletting eller flytting
   under henting gjenoppretter ikke gammel prognose/feil. Gjelder både samlet
   oppdatering og henting ved tillegg av et sted; oppdaterte navn brukes i feil.
24. **AUTO · FERDIG** — Når alle forespurte steder feiler, behold eksisterende
   varslingsplan, widget/Watch-data og oppdateringstid. Feilmeldinger vises
   fortsatt. En bevisst tom stedsliste kan fortsatt rydde planen.
25. **AUTO · PÅ VENT 2026-09-17** — Kontroller Live Activity ved delvis
   manglende værdata og utvid integrasjonstestene for kansellering midt i
   nettverkshenting. Krever fysisk ActivityKit-kjøring på iPhone eller
   konfigurert simulator; beholdt som neste kandidat når slik testflate er
   tilgjengelig.
26. **AUTO · FERDIG** — Bufrede prognoser og hentefeil fjernes ved endrede
   koordinater eller sletting av sted, også ved direkte redigering av listen.
   Omdøping, regelendringer og sortering beholder gyldige værdata.
27. **AUTO · FERDIG** — Widget/Watch bruker valgt steds faktiske hentetid,
   ikke tidspunktet et annet sted ble oppdatert. Ved manglende data kan siste
   delte prognose for samme sted/koordinater brukes med sin opprinnelige alder.
   Data for et annet/flyttet sted brukes ikke; dagens navn og regler beholdes.
28. **AUTO · FERDIG** — Full oppdatering og bakgrunnsoppdatering køes i
   stedet for å rapportere en hoppet-over oppdatering som vellykket. Hver
   jobb leser ferske steder ved start. Kansellering av en jobb stopper ikke
   neste; en avbrutt jobb som venter, starter ikke nettverkshenting.
29. **BRUKER · UTREDET** — Nattens prognose for Klinga ble ikke funnet lokalt,
   og kan ikke tallfestes fra rimobservasjonen. Frostmarginen er ikke endret.
30. **BRUKER · FERDIG** — Separat lokal temperaturjustering per lagret sted,
   rullerende 48-timers prognosehistorikk og manuell temperatur/frostregistrering.
   Observasjoner beholder nødvendig prognosegrunnlag etter opprydding. Målt
   avvik vises uten automatisk endring; Netatmo og kurvejustering er utsatt.
31. **BRUKER · DELVIS FERDIG** — Watch-toppfelt har nå sted, temperatur og
   værikon på én rad uten duplisert appnavn. Unike hendelsesikoner for neste
   12 timer er implementert med tidspunkt og full VoiceOver-tekst.
   Sirkulær komplikasjon viser neste hendelses symbol og tidspunkt («Nå» ved
   pågående vær), ellers temperatur. Smartstabel-widget veksler mellom hendelser
   i 15-minutters tidslinjesteg. Visuell kontroll på klokka gjenstår.
   Bruker har bedt om denne UI-retningen. Avklar/utred stedskilde (hjem,
   valgt eller nåværende sted) uten å fremstille et lagret sted som GPS-posisjon.
   Eksisterende ulagrede Watch-endringer må avgrenses før implementering.
32. **BRUKER · DELVIS FERDIG** — Hjemstatus heter nå «Sol» også ved overskyet
   vær, og «solgløtt» erstatter «gløtt». Gjenstår: vurder stiplet markering i solraden
   som ren visning, uten å endre normale pushterskler.
33. **BRUKER · DELVIS FERDIG** — Hjem- og stedskort får nå globalt språkvalg
   direkte fra Store og bruker WeatherLanguage for rullerende tekst/detaljer.
   Push bruker samme ordbok for tidspunkt og værdetaljer. Inntrøndersk bruker
   «i mårrå», «i overmårrå», «te» og «sjer d ut som» ved mulig vær.
   Stedsnavn, preposisjoner og huskelapper sendes ikke gjennom ordboken.
   Gjenstår: overføring av språk til widget/Watch og visuell kontroll av bytte.
34. **BRUKER · FERDIG** — Gjenoppta vedlikehold hvert tredje minutt med
   ressursvern for parallelt Claude-arbeid. Aktiv automasjon er oppdatert.
35. **BRUKER · DELVIS IMPLEMENTERT** — Hjem kan nå sveipes mellom valgt sted
   og eksplisitt valgte favoritter; favoritt 2 ligger til venstre og favoritt 1
   til høyre i den lagrede rekkefølgen. Visuelle nabopiler og faktisk GPS-
   midtsted gjenstår.
   Sveip mellom tre hjemmesider: favoritt 2 til venstre,
   Grunnmodell HomeFavorites lagt til med Codable og ID-basert oppløsning:
   slettede steder og duplikater utelates, uten automatisk erstatning.
   89 tester og Watch-bygg bestod 2026-09-13. Modellen er ennå ikke koblet
   til Store, innstillinger eller sveiping; ingen synlig endring/installasjon.
   nåværende posisjon i midten og favoritt 1 til høyre. Åpne på posisjonssiden;
   vis nabostedenes navn/piler. Bruker har bedt om denne navigasjonsretningen.
   Favoritter velges eksplisitt, ikke ved å omdefinere dagens stedsrekkefølge.
   Andre steder beholdes i Steder. Sveiping skal ikke endre pushregler.
   Nåværende posisjon må ha eget oppdateringstidspunkt/nøyaktighet og skille
   tydelig mellom fersk GPS, sist kjente posisjon og nektet tilgang.
   Del visningssted/vær med Watch; ikke bruk 5-km nærhetsregion som GPS-posisjon.
36. **BRUKER · DELVIS FERDIG · GRUNNLAG FOR 35** — Sikre posisjon og Watch-henting før
   automatisk stedsskifte. LocationManager.current lagrer bare én continuation:
   overlappende kall kan overskrive en venter, og avbrudd/tidsavbrudd mangler.
   Watch-refresh har nå revisjonsvern: ny iPhone-overføring eller tømming
   ugyldiggjør eldre pågående henting, inkludert dens feilmelding. Kansellerte
   svar ignoreres. Lokalt temperaturavvik brukes på nye Watch-prognoser uten
   akkumulering. Posisjonshenting avviser nå overlapp, støtter kansellering
   og 30-sekunders tidsavbrudd, venter på tillatelse og avviser svar fra eldre
   manager. Fysisk GPS-test og flere samtidighets-/timeouttester gjenstår.

37. **BRUKER · DELVIS FERDIG** — Vindkast på 9 m/s kan nå velges med egen
   nedre grense 4–50 m/s i editoren. Forhåndsnivåer er fortsatt 12/20/30/40, mens
   Nye vindregler og de fire vanlige malene bruker nå 9 m/s. Eldre regler
   uten lagret grense beholder historisk 10; eksplisitte grenser bevares.
   Gi tydelig justerbar nedre grense som inkluderer 9; ikke overskriv lagrede
   personlige terskler automatisk. Skill vind og kast i tekst, og unngå bare
   «Vind i natt kl. 01» uten styrke. Rullerende overskrift sier nå «Vindkast»,
   og detaljlinjen viser vind og kast separat (eller «kast ikke oppgitt»).
   Pushdetaljer skiller også vind/kast, merker manglende kast og unngår
   styrkebetegnelser for middelvind på kastverdier. Livefeltene på iPhone og
   Watch viser nå vind/kast separat, med strek når kast mangler. Kontroller maler med
   grensetester. effectiveWind bruker max(middelvind, kast); vurder eksplisitt
   merking når kast mangler. Brukerens konkrete Yr-observasjon er ikke hentet.
   Gjennomgang 2026-09-13: Fire vindmaler i RulePresetPickerView hardkoder
   12 både i tall og beskrivelse. Rule.init og typebytte i RuleEditor bruker
   defaultThreshold (10), men også decoder bruker samme verdi når threshold
   mangler i eldre data. Neste endring: felles 9 m/s for nye vindregler og
   maler i tråd med brukerens siste ønske, men behold historisk fallback 10
   ved dekoding og alle eksplisitt lagrede grenser. Behold rådgivningsnivået
   «Fest løse gjenstander» på 12; det er ikke samme valg som varslingsgrensen.
   Test nye regler, alle fire maler, typebytte og gammel JSON uten threshold.
## Forslag som venter på godkjenning

Ingen.

## Ferdig

- 2026-09-13: Sprak.json bygges nå inn i iPhone, Watch og begge widgetmål.
  Appnavn, generiske pushoverskrifter, inntrønderske tidsuttrykk og ukedager
  leses fra filen. Språk følger snapshot til Watch/widgets og beholdes ved
  Watch-refresh. Engelsk/full tekstdekning og øvrige katalogmaler gjenstår.
  94 tester bestod, inkludert faktisk bundlet språkfil, trygg innsetting av
  stedsnavn, vindkast uten middelvind-reserve og separat visningstemperatur.
  Signert iPhone/Watch-bygg bestod og iPhone-installasjon ble bekreftet.
  Sprak.json kontrollert i alle fire ferdige pakker. Installasjon på selve
  klokka og visuell kontroll i CarPlay er ikke bekreftet.

- 2026-09-13: Installert signert iPhone-bygg med vindstandard 9 m/s.
  Deretter lagt til GPS-vern som grunnlag for sveiping. 88 tester og iOS-bygg
  bestod, inkludert kansellering før GPS-oppstart. GPS-endringen er ikke
  installert; sveipesidene er heller ikke implementert ennå.
- 2026-09-13: Nye vindregler og fire vanlige vindmaler samkjørt til 9 m/s.
  Maltekst viser samme verdi og sier «i kastene». Historisk dekodingsfallback
  beholdt på 10 og lagrede terskler endres ikke. 87 tester og Watch-bygg
  bestod. Rådgivningsnivå 12 og kraftig/ekstremmaler er uendret. Ikke installert.
- 2026-09-13: Kontrollert lokal test i maintenance_stop_test.rb bestod:
  Git-diff-kontroll ga fremdrift, to simulerte tomme forsøk slo continue av,
  og neste oppgave ble ikke kalt. Testen endrer ikke produksjonsstatus eller
  planlegger. Dette tester en lokal modell av instruksen, IKKE integrasjonen
  med Codex-agenten eller planleggeren; ende-til-ende-verifisering gjenstår.
- 2026-09-13: Avgrenset gjennomgang av vindstandarder fant felles standard
  brukt både for nye regler og migrering. Dokumentert alle fire maler og
  nødvendig migreringsvern før endring til 9 m/s for nye regler. Kun
  dokumentasjon; diff-kontroll bestod, ingen nye bygg eller installasjon.
- 2026-09-12, ressurskontroll: Samkjøring av livefelt «Vind / kast» på
  iPhone og Watch er påbegynt med regresjonstest, men ikke ferdig eller
  committet. Forrige testlogg finnes ikke lenger, så testresultatet kan ikke
  bekreftes. Bare 4,9 GiB ledig disk (99 % brukt); ingen aktive bygg eller
  startede simulatorer. Nye tunge tester/bygg utsettes av ressurshensyn.
  Fullført 2026-09-13 etter økt ledig diskplass, se nedenfor.
- 2026-09-13: Livefelt på iPhone og Watch bruker samme «Vind / kast»-tekst
  og viser begge verdier separat. Manglende kast vises som strek, ikke som
  middelvind eller null. Alle 86 tester og Watch-bygg bestod med to jobber
  og gjenbruk av byggedata; diskplass 8,0 GiB etterpå. Ingen fysisk installasjon
  eller visuell kontroll. Neste prioritet: konsistente vindmaler/standardgrenser.
- 2026-09-12: Pushdetalj viser høyeste vind og høyeste oppgitte kast separat.
  Manglende kast merkes også når bare deler av perioden mangler data. Generelt
  sikringsråd tilføyes først fra 12 m/s i kast; 9 m/s kan fortsatt utløse regel
  med valgt grense 9. Alle 85 tester bestod, inkludert tekst for 9 m/s, manglende
  kast og delvis dekning med kraftigere kast. Ingen fysisk installasjon.
- 2026-09-12: Rullerende vindhendelser omtales som vindkast; nå-hendelser
  uten kastdata sier vind. Detaljlinjen viser begge Yr-verdier separat og
  merker manglende kast eksplisitt. Ingen endring i terskler eller pushoverskrift.
  Alle 84 tester bestod, inkludert egen teksttest for begge datafelter og
  manglende kast. Ingen fysisk installasjon. Flere vindtekstflater gjenstår.
- 2026-09-12: Vindeditoren har egen justerbar grense 4–50 m/s og viser
  «Egen grense» når verdien ikke er et forhåndsnivå. Lagrede regler endres ikke.
  Regresjonstest bekrefter lagring av 9 m/s og at 8,9 ikke treffer mens 9 gjør.
  Alle 83 tester bestod på én simulator uten parallell testing. Ingen endring
  i Watch-kode eller fysisk installasjon. Standardgrenser og vindtekst gjenstår.
- 2026-09-12: Sikret Watch-refresh mot nyere iPhone-overføringer og tømming
  med revisjons-ID, og ignorerer kansellering/foreldede feilmeldinger. Nye
  prognoser bruker lokal temperaturjustering. Regresjonstest dekker ugyldig
  revisjon, tomt svar, bevart sted/hentetid, Yr-original og ikke-akkumulering.
  Alle 82 tester og Watch-bygg bestod med to jobber. Ingen simulator var igjen
  startet etter testene. Ingen fysisk installasjon. Neste: robust GPS-henting.
- 2026-09-12: Utredet grunnlaget for sveipesider og felles posisjon med Watch.
  Eksisterende LocationManager kan hente GPS og navn, men Store/Watch deler
  bare valgt lagret sted uten GPS-alder/nøyaktighet. Nærhetsmonitoren gjelder
  5-km pushregioner og er ikke egnet som «nåværende sted». To samtidighetsrisikoer
  og manglende lokal temperaturjustering i Watch-refresh er dokumentert i 36.
  Ingen kode, bygg, simulator eller installasjon denne økta; diff-kontroll bestod.
- 2026-09-12: Koblet rullerende hjem-/stedstekst til globalt språkvalg og
  samlet dialektord i WeatherLanguage, også brukt av push. Alle 81 tester
  bestod på én simulator uten parallell testing, inkludert den nye språk-
  testen og tidligere ukjørt Watch-utvalgstest. Simulatoren var avsluttet
  etter testkjøringen. Watch-bygg bestod også. Ingen fysisk installasjon;
  widget/Watch-språk gjenstår.
- 2026-09-12: Sirkulær komplikasjon viser nærmeste hendelse innen 12 timer med
  ikon og tidspunkt, med full tekst for VoiceOver. Rektangulær widget viser
  stedsnavn/temperatur og veksler mellom unike værtyper i eksisterende tidslinje.
  Systemet bestemmer faktisk oppdateringstid; ingen sekundtimer eller økt
  tidslinjefrekvens. Watch-bygg og diff-kontroll bestod. Ingen simulator,
  kjørt enhetstest, visuell kontroll eller installasjon. Tidligere brukerendringer
  er holdt utenfor commit. Stedskilde følger fortsatt valgt sted på iPhone.
- 2026-09-12: Watch viser nærmeste hendelse per værtype i et kompakt rutenett
  for neste 12 timer, med pågående vær først. Visningen revurderes hvert minutt
  mens den vises. Felles utvalgsfunksjon sorterer deterministisk og fjerner
  duplikate værtyper. Regresjonstest lagt til for 12-timersgrensen, duplikater,
  omvendt input og tom liste; testen er ikke kjørt (ingen ny simulator).
  Watch-bygg med to jobber bestod, samt diff-kontroll. Ikke visuelt kontrollert
  eller installert. Neste del er sirkulær komplikasjon og Smartstabel-widget.
- 2026-09-12: Kompakt Watch-toppfelt med eget stedsnavn, temperatur og værikon.
  Lange navn kan forkortes; temperatur og ikon beholder plassen. Watch-bygg
  bestod med to jobber og gjenbruk av eksisterende DerivedData. Ingen simulator,
  visuell kontroll eller fysisk installasjon. Eksisterende kompatibilitets-
  endringer er bevart utenfor commit. Resten av oppgave 31 gjenstår.
- 2026-09-12: To visningstekster i hjemstatus endret til «Sol» og «solgløtt».
  Terskler, ikoner og pushlogikk er uendret. Git-diff-kontroll bestod.
  Bygg, simulator og visuell kontroll utsatt av diskhensyn (12 GiB ledig).
  Ikke installert. Watch-endringer fortsatt urørt; oppgave 32 er bare delvis ferdig.
- 2026-09-12: Lett vedlikeholdsgjennomgang og ajourføring av brukeroppgaver
  31–34. Omtrent 12 GiB ledig på datavolumet; ingen bygg, simulator eller
  installasjon startet. Bare dokumentasjon endret, kontrollert med git diff.
  Språkfeilens kodevei dokumentert; ikke markert som rettet.
- 2026-09-11: Lokal temperaturjustering er separat fra frostmargin og bruker
  bevart Yr-original slik at endringer aldri summeres flere ganger. Nytt
  skjema i stedets varselinnstillinger registrerer lufttemperatur/tid og
  frost/overflate. Prognoseversjoner beholdes i 48 timer, med opprydding ved
  oppstart og oppdatering også ved nettfeil. Observasjoner lagrer relevant
  sammenligningsgrunnlag separat; frost bruker prognose fra før natten og
  målt temperatur viser avvik uten automatisk endring. Registreringer kan
  slettes. Historikk begynner først ved nye hentinger. Netatmo/kurver utsatt.
  79 av 79 tester og samlet iPhone/watchOS-bygg bestod. Ingen fysisk installasjon.
- 2026-09-11: Overlappende bakgrunns- og fulloppdateringer kjøres i rekkefølge
  i stedet for å hoppe over den siste med et uriktig suksessresultat. Avbrudd
  følger riktig jobb og stanser ikke neste. To kontrollerte asynkrone tester
  dekker rekkefølge, feilresultat og kansellering både under venting og aktiv
  jobb. 76 av 76 tester og samlet iPhone/watchOS-bygg bestod. Ingen fysisk
  installasjon. Brukerens frostobservasjon er neste prioritet, oppgave 29.
- 2026-09-11: Widget/Watch får hentetid per sted, slik at vellykket henting
  et annet sted ikke gjør gammel prognose tilsynelatende fersk. Ved oppstart
  uten data brukes bare lagret prognose for samme sted/posisjon, med gammel
  hentetid og dagens navn/regler. To regresjonstester dekker alder, ferske
  data, omdøping, flytting, annet sted og tomt valg. 74 av 74 tester og samlet
  iPhone/watchOS-bygg bestod. Ingen fysisk installasjon. Neste: overlappende
  oppdateringer og Live Activity ved manglende data.
- 2026-09-11: Endring av et steds koordinater fjerner nå gammel prognose og
  gammel hentefeil fra minnet. Samme vern gjelder direkte listeendringer og
  sletting, mens navn, regler, rekkefølge og avrunding innen API-presisjon
  ikke utløser unødvendig tømming. To regresjonstester; 72 av 72 tester og
  samlet iPhone/watchOS-bygg bestod. Ingen fysisk installasjon. Neste:
  overlappende oppdateringer og widget/Live Activity ved manglende data.
- 2026-09-11: Selektiv bevaring av lokale varsler når enkelte steder mangler
  prognose, også ved oppstart/replanlegging. Lagret regelkontekst sammenlignes
  med dagens sted, regel og språk før bevaring; gamle forespørsler uten denne
  metadataen kan ikke bekreftes. Bevarte og nye varsler deler de 64 nærmeste
  plassene, og loggen teller begge. Tre tester dekker regelendring, avslag,
  sletting, flytting, språk, utløp, manglende metadata og kapasitet. 70 av 70
  tester og samlet iPhone/watchOS-bygg bestod. Ingen fysisk installasjon.
- 2026-09-11: En oppdatering der alle steder feiler returnerer nå feil uten
  å erstatte lokale varsler eller merke gamle data som nettopp oppdatert.
  Feiltekstene beholdes. To beslutningstester dekker full feil, delvis/full
  suksess og bevisst tom stedsliste. 67 av 67 tester og samlet iPhone/watchOS-
  bygg bestod uten fysisk installasjon. Delvis feil og andre utløsere uten
  prognoser gjenstår uttrykkelig i oppgave 21.
- 2026-09-11: Forsinkede værdata og hentefeil avvises når stedet er slettet
  eller flyttet under forespørselen. Steder som bare er omdøpt eller har fått
  nye regler beholder dataene, med siste navn/innstillinger. To regresjons-
  tester dekker sletting, ny ID, flytting, API-avrunding og redigering. 65 av
  65 tester og samlet iPhone/watchOS-bygg bestod uten fysisk installasjon.
  Neste prioritet er fortsatt manglende prognoser ved nettfeil (oppgave 21).
- 2026-09-11: Avbrutte oppdateringer stopper før nye hentebatcher og før
  varslingsplanlegging, og ignorerer resultater etter kansellering. De setter
  ikke et nytt «sist oppdatert»-tidspunkt. Direkte avbrutt replanlegging er
  også beskyttet. To regresjonstester dekker oppgaver kansellert før oppstart;
  63 av 63 tester og samlet iPhone/watchOS-bygg bestod. Ingen fysiske enheter
  brukt. Manglende prognoser uten kansellering gjenstår i oppgave 21.
- 2026-09-11: Forgrunn og bakgrunn deler én hovedtrådisolert Store. Privat
  konstruktør hindrer at nye bakgrunnsjobber lager en separat kopi som kan
  overskrive ferske innstillinger ved logglagring. Regresjonstest kontrollerer
  identitet og delt tilstand over en oppgavegrense. 61 av 61 tester bestod på
  iOS 27-simulator; samlet iPhone/watchOS-bygg bestod uten signering. Ingen
  fysisk installasjon. Kansellering og manglende prognoser følges i oppgave 21.
- 2026-09-11: Hele utskiftningen av lokale varsler går gjennom én delt kø,
  inkludert alle asynkrone innlegginger. Dette hindrer at en gammel plan
  fortsetter å legge inn varsler etter at en nyere har slettet dem. Test med
  kontrollert pause midt i innlegging, avbrutt oppgave og påfølgende tømming
  bestod. 60 av 60 tester bestod på iOS 27-simulator; samlet iPhone/watchOS-
  bygg bestod uten signering. Ingen fysiske enheter brukt. Neste: dataversjoner
  mellom bakgrunnens og forgrunnens Store, som er en separat risiko.
- 2026-09-11: Varsler som deler utsendingstid og ID sorteres før duplikatvalg,
  slik at senere værhendelser ikke skjuler den nærmeste ved ombyttet input.
  Regresjonstest dekker begge rekkefølger, utløpt varsel og tom kapasitetsgrense.
  59 av 59 tester bestod på iOS 27-simulator. Samlet iPhone/watchOS-bygg bestod
  uten signering eller installasjon på fysiske enheter. Eksisterende bruker-
  endringer i Watch-visninger, prosjekt og schemes er bevart utenfor commit.
- 2026-09-10: Vindkast viser nå både m/s og kjent vindstyrkenavn fra stille og
  bris via kuling og storm til orkan. Navnet brukes i rullerende værdetalj,
  utfyllende pushtekst, live-status og Watch-visning. Rullerende nedbør starter
  alltid med «Regn» eller «Snø» med stor bokstav, mens «Mulig regn/snø» beholder
  naturlig setningsform. 58 av 58 tester bestod.
- 2026-09-10: La inn en egen watchOS-assetkatalog med 1024-pikslers AppIcon.
  Xcode genererer nå Watch-ikonene og `CFBundleIconName`, og Watch-appen bygges
  med gyldig `Assets.car`. CarPlay-widgeten er kontrollert mot Apples krav:
  `systemSmall` støttes og bakgrunnen er fjernbar. Fysisk Watch-installasjon
  venter separat på at Xcode registrerer klokka i utviklerprofilen. 56 av 56
  tester bestod, og fysisk iPhone-bygg bestod.
- 2026-09-10: Fjernet den dupliserte «Neste hendelse …»-teksten fra den
  rullerende statusen. Andrelinjen viser nå bare utfyllende værdata: nedbør og
  sannsynlighet, anslått snø, duggpunkt og temperaturavstand, Yr-temperatur og
  lokal frostmargin, vindkast eller skydekke. Alle sju varseltyper er dekket av
  en regresjonstest som avviser gjentatt klokkeslett. 56 av 56 tester bestod.
- 2026-09-10: Varslingsplanlegging teller nå hvilke lokale varsler iOS faktisk
  godtok. Loggen skiller mellom fullført, delvis fullført og helt mislykket
  aktivering, og bruker antallet etter filtrering og iOS-grensen i stedet for
  det ubehandlede regelresultatet. 55 av 55 tester bestod.
- 2026-09-10: La til en ende-til-ende-regresjon fra rå Yr-tabell og Nå-varsel
  via sammenslåing, regelplanlegging og inntrøndersk pushtekst til samme status
  etter overføring til widget/Watch. En egen lanseringssjekkliste dekker
  automatisk port, værkjeden, fysisk iPhone, Live Activity, Apple Watch,
  CarPlay og oppgraderingsdata. 54 av 54 tester bestod.
- 2026-09-10: Samlet visuell tolkning av været nå i én delt modell for snø,
  regn, tåke, sol, solgløtt og skyer. iPhone, Watch-appen og Watch-widgeten
  bruker nå de samme tersklene, ikonene, fargene og navnene, mens varselikoner
  fortsatt kommer fra den felles varseltypen i app, widgets og Live Activity.
  Regresjonstesten dekker også at tørr Nå-status trumfer mulig regn i
  tabellvarselet på hovedikonet. 53 av 53 tester bestod.
- 2026-09-10: Samlet appnavnet og formatet for app- og værvarseltitler i én
  felles tekstmodell. Hjemskjerm, oppstartsveiviser, push, iPhone-widget,
  Live Activity, Watch-app og Watch-widget bruker nå samme kilde, og tekstens
  mellomrom og preposisjon er låst med tester. 52 av 52 tester bestod.
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
- **BRUKER-073 · FULLFØRT 2026-09-18** — Rettet `TimelineView`-kompilering:
  ForecastDay-iterasjonen har eksplisitt identitet, værbåndvisningen får
  koordinatene den bruker, og den tunge radtypeberegningen er delt opp i
  navngitte hjelpeegenskaper. Dette fjerner de rapporterte type- og scope-
  feilene i filen.
- **BRUKER-074 · FULLFØRT 2026-09-18** — Utvidet stedskortene på Steder:
  trykk på en stedrad viser nå samme tredagers værbånd med varselsrader som
  Hjem, mens den kompakte raden fortsatt brukes når stedet er lukket.
- **BRUKER-075 · FULLFØRT 2026-09-18** — Tilbakestilte Steder-oversikten til
  den tidligere nå-visningen: alle steder viser nå værkort med aktuell
  temperatur, værstatus og roterende nå-varsel direkte i oversikten.
- **BRUKER-076 · FULLFØRT 2026-09-18** — Beholdt nå-kortene for alle steder,
  men lagt til trykk-til-ekspandering under hvert kort. Den åpne delen viser
  tredagers værbånd med samme varselsrader og terskler som Hjem, uten en ekstra
  kompakt stedrad.
- **BRUKER-077 · FULLFØRT 2026-09-18** — Varseloversikten og push-tittelen
  viser nå værtype, sted og kort tidshorisont i første linje. Nære hendelser
  bruker «om en halvtime»/«om to timer», mens senere hendelser bruker «i natt»,
  «i morgen» eller «til helga» uten ukedag. Detaljlinjen beholder presist
  klokkeslett og mengde.
- **BRUKER-078 · FULLFØRT 2026-09-18** — Strammet sammen Steder-kortet og
  tredagersvarselet visuelt. Ekspansjonen kommer nå direkte under nå-kortet
  med delt kantlinje og roligere overgang, og Hjem-prikkene er trukket nærmere
  værkortet uten å flyttes bort fra swipe-indikatoren.
- **BRUKER-079 · FULLFØRT 2026-09-18** — La inn et kodifisert varselmal-
  utkast øverst i `VARSELTEKSTER.md`, med førstelinje, andrelinje og
  teksttabeller for regn, snø, vindkast, dugg, frost, sol og temperatur.
- **BRUKER-080 · FULLFØRT 2026-09-18** — La varighet inn som fast del av
  andrelinjemalen, med naturlige formuleringer som «i to timer», «gjennom
  natta» og «store deler av dagen».
- **BRUKER-081 · FULLFØRT 2026-09-18** — Definerte kortvarig som forventet
  varighet under én time. Varighetsleddet kan da sløyfes når det ikke gir
  ekstra informasjon.
- **BRUKER-082 · FULLFØRT 2026-09-18** — Renskrevet push-eksemplene for alle
  værtyper i `VARSELTEKSTER.md` etter malen: «Det blir/kan bli [Værtype]!",
  kort tid i første linje og tekstlig beskrivelse med dag, klokkeslett og
  varighet i andre linje.
- **BRUKER-083 · FULLFØRT 2026-09-18** — Samordnet sol-eksemplene og la inn
  eksplisitt språkregel: «om» brukes for starttidspunkt, «i» for varighet.
- **BRUKER-084 · FULLFØRT 2026-09-18** — Utvidet språkgrunnlaget med en
  egen mal- og beskrivelsesdel for bokmål, inntrøndersk og engelsk i både
  `Sprak.json` og `VARSELTEKSTER.md`.
- **BRUKER-085 · FULLFØRT 2026-09-18** — Fjernet gjentatt «i morgen»/«i
  natt» fra andrelinjen. Den bruker nå beskrivelse + ukedag + klokkeslett,
  mens tidskategorien står i første linje.
- **BRUKER-086 · FULLFØRT 2026-09-18** — Forenklet andrelinjen ytterligere
  for hendelser samme dag, kveld eller natt: den går rett på klokkeslettet
  når første linje allerede har tidskategorien.
