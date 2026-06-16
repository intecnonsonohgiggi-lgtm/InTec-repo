# SiriAIOverhaul

Tweak iOS Rootless per sostituire Siri con ChatGPT o Google Gemini,  
con bordo glow ottimizzato per Apple A9 (iPhone 6s).

---

## Struttura del Progetto

```
SiriAIOverhaul/
├── Makefile                          ← Build system (rootless, arm64)
├── control                           ← Metadati pacchetto .deb
├── entitlements.plist                ← Entitlement per iniezione sandbox
├── Tweak.x                           ← Hook Logos + motore AI + glow
└── SiriAIOverhaulPrefs/
    ├── Info.plist                    ← Bundle metadata
    ├── Root.plist                    ← Struttura UI Impostazioni
    └── SAPRootListController.m       ← Controller salvataggio preferenze
```

---

## Requisiti

| Componente        | Versione                          |
|-------------------|-----------------------------------|
| iOS               | 15.0 – 16.7.x                    |
| Jailbreak         | Dopamine (rootless)               |
| Hardware testato  | iPhone 6s (Apple A9, arm64)      |
| Theos             | ≥ 2.3                            |
| Clang             | incluso nel toolchain Theos       |
| Dipendenze deb    | ellekit, preferenceloader        |

---

## Compilazione

```bash
# 1. Clona o copia la cartella SiriAIOverhaul sul tuo Mac
# 2. Assicurati che THEOS sia configurato correttamente
export THEOS=/opt/theos

# 3. Compila
cd SiriAIOverhaul
make -j$(nproc)

# 4. Crea il pacchetto .deb
make package

# 5. Installa via SSH (IP del tuo iPhone)
make install THEOS_DEVICE_IP=192.168.x.x
```

---

## Configurazione

1. Apri **Impostazioni → SiriAI Overhaul**
2. Attiva il tweak con lo switch **Attivo**
3. Seleziona **ChatGPT** o **Gemini** dal segmento
4. Incolla la tua **API Key** nel campo testo
5. Il tweak è operativo: pronuncia **"Hey Siri"** come sempre

---

## Architettura Tecnica

### Flusso Dati

```
Hey Siri rilevato
        │
        ▼
[assistantd] SiriTriggerWordDetector::didDetect
        │  Darwin Notification → kHerySiriDidStart
        ▼
[SpringBoard] SAOGlowBorderView::startGlow        ← Glow si accende
        │
        ▼
[SpringBoard] SAOAIEngine::beginListening
        │
        ├─► SFSpeechRecognizer (on-device STT, zero rete)
        │         │ testo trascritto
        │         ▼
        ├─► NSURLSession (async, QoS .utility)
        │         │ POST /v1/chat/completions
        │         │ o Gemini generateContent
        │         ▼
        ├─► JSON parse → stringa risposta
        │         │
        │         ▼
        └─► AVSpeechSynthesizer::speakUtterance    ← TTS on-device
                  │
                  ▼
        SAOGlowBorderView::stopGlow               ← Glow si spegne
```

### Ottimizzazioni Energetiche (Apple A9)

| Area           | Tecnica                                          | Risparmio |
|----------------|--------------------------------------------------|-----------|
| GPU            | CAShapeLayer + CAKeyframeAnimation statica       | ~70% GPU  |
| CPU (STT)      | SFSpeechRecognizer on-device (iOS 15+)           | ~0% rete  |
| CPU (rete)     | NSURLSession ephemeral, 1 conn/host, QoS utility | thread scheduling |
| CPU (TTS)      | AVSpeechSynthesizer pool riutilizzato            | ~0 alloc  |
| Frame rate     | Animazione CA lenta 2.8s, no CADisplayLink       | ~60% GPU  |
| Thread         | dispatch_queue QoS .utility (sospendibile)       | thermal   |

### Iniezione Processi

Il tweak si inietta in **due** processi:

- **SpringBoard**: gestisce UI (glow border) + riceve notifiche Darwin
- **assistantd**: intercetta l'attivazione "Hey Siri" a basso livello

Il `%ctor` seleziona il gruppo di hook corretto in base a `processName`.

---

## Preferenze e Sicurezza

Le preferenze vengono salvate in:
```
/var/jb/var/mobile/Library/Preferences/com.tuonome.siriaioverhaul.plist
```

- Scrittura atomica (`writeToFile:atomically:YES`) → nessuna corruzione
- `CFPreferencesSynchronize` → cache cfprefsd aggiornata istantaneamente
- La chiave API è marcata come `isSecure:YES` → mascherata in UI

---

## Classi Private Agganciate

| Classe                                  | Framework         | Hook                              |
|-----------------------------------------|-------------------|-----------------------------------|
| `SiriTriggerWordDetector`               | AssistantServices | `didDetectTriggerWordWithConfidence:` |
| `SiriUIUnderstandingOnDeviceHandler`    | SiriUI            | `handleOnDeviceSpeechRecognitionResult:`, `presentUI` |
| `SiriUIAssistantWindowController`       | SiriUI            | `presentWithAnimation:`           |
| `SpringBoard`                           | SpringBoard       | `applicationDidFinishLaunching:`  |

> **Nota**: i nomi delle classi private variano tra versioni iOS.  
> Su iOS 16.x potrebbe essere necessario verificare i nomi attuali con  
> `class-dump` o un RE tool come Hopper su `/System/Library/PrivateFrameworks/SiriUI.framework`.

---

## Troubleshooting

**Il glow non appare**  
→ Verifica che `SAOGlowBorderView` venga aggiunta. Controlla i log con `oslog --predicate 'subsystem == "SAO"'`.

**"Hey Siri" apre ancora Siri nativo**  
→ La classe hook potrebbe avere nome diverso sulla tua versione iOS.  
→ Usa `cycript` o `frida` per trovare la classe corretta nel processo `assistantd`.

**Risposta molto lenta**  
→ Prova a passare a **Gemini 1.5 Flash** (più veloce di GPT-4o-mini su rete mobile).  
→ Riduci `max_tokens` a 128 nel codice per risposte brevissime.

**Surriscaldamento**  
→ Verifica con `powermetrics` (via SSH) il consumo GPU.  
→ Aumenta `kGlowDuration` a 4.0+ in `Tweak.x` per rallentare ulteriormente l'animazione.

---

## Licenza

Progetto educativo. Non distribuire chiavi API hardcoded.  
Usa a tuo rischio su dispositivi jailbroken.
