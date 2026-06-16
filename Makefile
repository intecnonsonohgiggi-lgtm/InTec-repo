# ==============================================================================
# SiriAIOverhaul — Makefile
# Target: iOS 15+ | Rootless (Dopamine) | arm64 (Apple A9 / iPhone 6s)
# ==============================================================================

# ── Schema rootless: tutti i path si basano su /var/jb ─────────────────────────
THEOS_PACKAGE_SCHEME = rootless

# ── SDK e target minimo ────────────────────────────────────────────────────────
TARGET := iphone:clang:latest:15.0

# ── Architettura: solo arm64 per A9, niente arm64e inutile su 6s ───────────────
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

# ==============================================================================
# TWEAK PRINCIPALE
# ==============================================================================
TWEAK_NAME = SiriAIOverhaul

SiriAIOverhaul_FILES = Tweak.x

# ── Framework necessari ────────────────────────────────────────────────────────
#   AVFoundation  → AVSpeechSynthesizer (TTS leggero, nativo)
#   Speech        → SFSpeechRecognizer  (STT on-device, zero rete)
#   AudioToolbox  → gestione sessione audio di sistema
SiriAIOverhaul_FRAMEWORKS = \
    UIKit \
    Foundation \
    AVFoundation \
    Speech \
    AudioToolbox \
    QuartzCore

# ── Flag di compilazione: ottimizzazione dimensione/velocità bilanciata ─────────
#   -Os  = ottimizza per dimensione (meno cache miss su chip datato)
#   -fno-objc-arc = ARC manuale per i path critici (gestiamo noi il retain)
#   NDEBUG = disabilita assert in produzione
SiriAIOverhaul_CFLAGS = \
    -Os \
    -DNDEBUG \
    -fobjc-arc \
    -Wno-unused-variable \
    -Wno-deprecated-declarations

# ── Injection targets ──────────────────────────────────────────────────────────
#   SpringBoard  → glow border + intercettazione Hey Siri UI
#   assistantd   → demone Siri in background (intercettazione audio/intent)
SiriAIOverhaul_INSTALL_TARGET_PROCESSES = SpringBoard assistantd

include $(THEOS_MAKE_PATH)/tweak.mk

# ==============================================================================
# PREFERENCE BUNDLE
# ==============================================================================
BUNDLE_NAME = SiriAIOverhaulPrefs

SiriAIOverhaulPrefs_FILES          = SiriAIOverhaulPrefs/SAPRootListController.m
SiriAIOverhaulPrefs_INSTALL_PATH   = /Library/PreferenceBundles
SiriAIOverhaulPrefs_FRAMEWORKS     = UIKit Foundation Preferences
SiriAIOverhaulPrefs_PRIVATE_FRAMEWORKS = Preferences
SiriAIOverhaulPrefs_CFLAGS         = -Os -fobjc-arc

include $(THEOS_MAKE_PATH)/bundle.mk

# ── Pulizia extra ──────────────────────────────────────────────────────────────
after-install::
	install.exec "killall -9 SpringBoard || true"
