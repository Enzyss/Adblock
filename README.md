# AdBlock per iOS

App iOS che blocca pubblicità, tracker e banner dei cookie **in Safari** e **nelle altre app**.

| Dove | Come funziona | Cosa blocca |
|---|---|---|
| **Safari** (e le app che usano Safari View Controller) | 3 estensioni *Content Blocker* (Pubblicità, Privacy, Fastidi) con le regole di EasyList, EasyList Italy, EasyPrivacy, Cookie List… convertite nel formato di Safari | Richieste verso server pubblicitari, tracker, elementi della pagina (banner, box sponsorizzati, avvisi cookie) |
| **Tutte le app** | Una *VPN locale* (Network Extension `NEPacketTunnelProvider`) che fa solo da **filtro DNS**: le richieste DNS verso domini pubblicitari ricevono `0.0.0.0`, le altre vengono inoltrate al DNS scelto (Cloudflare, Quad9, Google, AdGuard) | Pubblicità in-app (AdMob, Unity Ads, AppLovin, Facebook Audience…), tracker e analytics |

Il traffico normale **non passa dal tunnel**: viene instradato solo un indirizzo fittizio (`198.18.0.1`) usato come server DNS. Quindi niente rallentamenti, consumo di batteria minimo e nessun dato inviato a server esterni oltre alle normali risoluzioni DNS.

## Funzionalità

- Liste di filtri attivabili/disattivabili, scaricate e aggiornate automaticamente (anche in background)
- Convertitore integrato da sintassi Adblock Plus/AdGuard a regole Safari (fino a 150.000 regole per estensione, ×3)
- Blocco DNS di sistema con statistiche e **registro delle richieste in tempo reale**
- Dal registro: scorri su un dominio per **consentirlo** o **bloccarlo**
- Lista di siti consentiti (whitelist) valida sia per Safari sia per le app
- Domini bloccati personalizzati e regole personalizzate in sintassi Adblock
- Interfaccia in italiano

## Limiti (onesti) di iOS

- **YouTube**: le pubblicità di YouTube (app e sito) arrivano dagli stessi server dei video, quindi né il filtro DNS né i content blocker possono rimuoverle senza bloccare anche i video. Nessun ad blocker iOS senza jailbreak ci riesce in modo affidabile nell'app ufficiale.
- Alcune pubblicità in-app servite dallo stesso dominio dei contenuti (es. Instagram, Facebook, TikTok) non sono bloccabili via DNS.
- Il blocco nelle app usa lo slot VPN di iOS: non può essere attivo **insieme a un'altra VPN**.
- Safari non supporta scriptlet e CSS esteso: questi filtri vengono ignorati (l'app mostra quanti).

## Requisiti

- Mac con **Xcode 15** o successivo
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- **Account Apple Developer a pagamento (99 €/anno)** per il blocco nelle app: le Network Extension (`packet-tunnel-provider`) non sono disponibili con l'account gratuito. Le sole estensioni di Safari funzionano anche con l'account gratuito (rimuovendo il target `PacketTunnel` e il relativo entitlement).
- iPhone con iOS 16 o successivo

## Come compilarla e installarla

1. Apri `project.yml` e modifica:
   - `APP_BUNDLE_ID` → un identificatore tuo, es. `com.tuonome.adblock`
   - `APP_GROUP_ID` → `group.` + lo stesso identificatore, es. `group.com.tuonome.adblock`
   - `DEVELOPMENT_TEAM` → il tuo Team ID (lo trovi su developer.apple.com → Membership)
2. Genera il progetto e aprilo:
   ```sh
   xcodegen generate
   open AdBlock.xcodeproj
   ```
3. In Xcode seleziona il tuo iPhone e premi **Run**. Con la firma automatica Xcode crea App ID, App Group e capability necessarie.
4. Sull'iPhone:
   - Apri l'app: al primo avvio scarica e compila i filtri.
   - **Safari**: Impostazioni → App → Safari → Estensioni → attiva *AdBlock Pubblicità*, *AdBlock Privacy* e *AdBlock Fastidi*.
   - **App**: nell'app attiva *Blocca pubblicità nelle app* e accetta l'aggiunta della configurazione VPN.

## Struttura del progetto

```
project.yml                     Definizione del progetto Xcode (XcodeGen)
App/                            App SwiftUI
  Sources/FilterManager.swift   Download, conversione e installazione dei filtri
  Sources/TunnelManager.swift   Installazione/avvio del filtro DNS
  Sources/Views/                Schermate (Protezione, Filtri, Attività, Eccezioni)
Extensions/
  ContentBlocker/               Codice condiviso dalle 3 estensioni Safari
  PacketTunnel/                 Filtro DNS di sistema (VPN locale)
Packages/AdBlockCore/           Logica pura e testata:
  SafariRuleConverter.swift     Sintassi Adblock → regole Safari
  DomainBlocklist.swift         Lista domini compatta (hash 64 bit, ~8 byte/dominio)
  DNSMessage.swift              Parsing/costruzione pacchetti DNS
  IPv4UDPPacket.swift           Parsing/costruzione pacchetti IP/UDP
  DNSPacketFilter.swift         Decide se bloccare o inoltrare una query
```

## Test

```sh
swift test --package-path Packages/AdBlockCore
# Test completo: scarica le liste reali e le fa compilare a WebKit
ADBLOCK_LIVE_TESTS=1 swift test --package-path Packages/AdBlockCore
```

La GitHub Action in `.github/workflows/build.yml` esegue i test (compresi quelli con le liste reali) e compila l'app per il simulatore a ogni push.

## Pubblicazione sull'App Store

Apple accetta ad blocker per Safari e app con filtro DNS tramite VPN locale (es. AdGuard, 1Blocker, Lockdown), purché la VPN non raccolga dati degli utenti e la privacy policy lo dichiari. Verifica le licenze delle liste di filtri che distribuisci (EasyList: GPLv3/CC BY-SA).
