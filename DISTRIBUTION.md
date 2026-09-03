# Compilazione e distribuzione di zzPDF

Questa guida copre l'uso locale, la firma Developer ID, la notarizzazione e la pubblicazione di una release GitHub.

## 1. Preparazione del Mac

Installare Xcode dall'App Store, aprirlo almeno una volta e accettare la licenza. Quindi verificare:

```bash
xcode-select -p
swift --version
xcrun --sdk macosx --show-sdk-path
```

Se necessario, selezionare Xcode:

```bash
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
```

## 2. Build locale

```bash
./build-app.sh
```

Lo script compila in modalità release, costruisce `outputs/zzPDF.app`, applica una firma locale ad hoc, ne verifica l'integrità e crea `outputs/zzPDF-macOS.zip`.

Per provare l'app:

```bash
open "outputs/zzPDF.app"
```

## 3. Certificato per la distribuzione

Iscriversi all'Apple Developer Program e creare o installare nel Portachiavi un certificato **Developer ID Application**. Elencare le identità disponibili con:

```bash
security find-identity -v -p codesigning
```

Ricompilare indicando il nome esatto del certificato:

```bash
SIGN_IDENTITY="Developer ID Application: NOME (TEAMID)" ./build-app.sh
```

Quando `SIGN_IDENTITY` non è `-`, lo script abilita Hardened Runtime e timestamp sicuro.

Verificare firma e compatibilità Gatekeeper:

```bash
codesign --verify --deep --strict --verbose=2 "outputs/zzPDF.app"
spctl --assess --type execute --verbose=2 "outputs/zzPDF.app"
```

Prima della notarizzazione, `spctl` può indicare che il pacchetto non è ancora notarizzato: è previsto.

## 4. Credenziali per la notarizzazione

Salvare una sola volta le credenziali nel Portachiavi. Apple richiede una password specifica per app:

```bash
xcrun notarytool store-credentials "zzPDF-notary" \
  --apple-id "APPLE_ID" \
  --team-id "TEAM_ID" \
  --password "PASSWORD_SPECIFICA_PER_APP"
```

Le credenziali non vengono salvate nel repository.

## 5. Notarizzazione

Dopo aver creato una build firmata con Developer ID:

```bash
./scripts/notarize.sh
```

Lo script invia lo ZIP ad Apple, attende il risultato, applica il ticket all'app e ricrea lo ZIP finale. Per usare un profilo diverso:

```bash
NOTARY_PROFILE="nome-profilo" ./scripts/notarize.sh
```

Controllo finale:

```bash
xcrun stapler validate "outputs/zzPDF.app"
spctl --assess --type execute --verbose=2 "outputs/zzPDF.app"
```

## 6. Pubblicazione su GitHub

Creare un tag coerente con `CFBundleShortVersionString` in `AppResources/Info.plist`:

```bash
git tag -a v0.3.0 -m "zzPDF 0.3.0"
git push origin main --tags
```

Nella pagina **Releases** del repository, creare una release dal tag e allegare `outputs/zzPDF-macOS.zip`. Pubblicare soltanto lo ZIP generato dopo la notarizzazione.

## 7. Aggiornare la versione

Prima di ogni release modificare in `AppResources/Info.plist`:

- `CFBundleShortVersionString`: versione pubblica, per esempio `0.4.0`.
- `CFBundleVersion`: numero di build crescente, per esempio `2`.

Ricompilare, rifirmare, notarizzare e creare il tag corrispondente.

## Note

- Non aggiungere al repository password, profili di notarizzazione esportati o certificati `.p12`.
- Il pacchetto generato su un Mac Apple Silicon è arm64. Per una release universale occorre compilare anche per x86_64 e combinare i binari con `lipo`, oppure usare un progetto Xcode configurato con `ARCHS = arm64 x86_64`.
- La distribuzione tramite Mac App Store richiede sandboxing, profili di provisioning e una pipeline distinta dalla distribuzione Developer ID descritta qui.
