// ==============================================================================
//  SAPRootListController.m
//  SiriAIOverhaul — Preference Bundle
//
//  Gestisce il salvataggio delle preferenze in cfprefsd redirected path:
//  /var/jb/var/mobile/Library/Preferences/com.tuonome.siriaioverhaul.plist
//
//  Strategia di salvataggio:
//  - NSDictionary → file plist via writeToFile:atomically:
//    (scrittura atomica: nessun rischio di corruzione del file)
//  - CFPreferencesSetMultiple per notificare cfprefsd (cache sync)
//  - PostNotification Darwin per notificare il tweak in tempo reale
// ==============================================================================

#import <Preferences/PSListController.h>
#import <Preferences/PSTableCell.h>
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>

// Path rootless: /var/jb è il prefix standard di Dopamine
static NSString *const kPrefsDomain = @"com.tuonome.siriaioverhaul";
static NSString *const kPrefsPath   =
    @"/var/jb/var/mobile/Library/Preferences/com.tuonome.siriaioverhaul.plist";
static NSString *const kPrefsChangedNotification =
    @"com.tuonome.siriaioverhaul.prefsChanged";

// ==============================================================================
@interface SAPRootListController : PSListController
@end

@implementation SAPRootListController {
    // Cache in-memory delle preferenze: evita letture disco ripetute
    NSMutableDictionary *_prefs;
}

// ── Metadati del pannello ──────────────────────────────────────────────────────
- (NSArray *)specifiers {
    if (!_specifiers) {
        // Carica Root.plist dalla stessa cartella bundle
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

// ── Titolo della navigation bar ───────────────────────────────────────────────
- (NSString *)title {
    return @"SiriAI Overhaul";
}

// ── viewDidLoad: carica preferenze esistenti ──────────────────────────────────
- (void)viewDidLoad {
    [super viewDidLoad];

    // Carica prefs da disco; se non esistono inizializza dizionario vuoto
    NSDictionary *onDisk = [NSDictionary dictionaryWithContentsOfFile:kPrefsPath];
    _prefs = [NSMutableDictionary dictionaryWithDictionary:onDisk ?: @{}];

    // Stile header personalizzato: logo testuale leggero (nessuna immagine aggiuntiva)
    UILabel *headerLabel     = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 320, 60)];
    headerLabel.text         = @"SiriAI Overhaul";
    headerLabel.font         = [UIFont systemFontOfSize:22.0 weight:UIFontWeightSemibold];
    headerLabel.textColor    = [UIColor systemBlueColor];
    headerLabel.textAlignment= NSTextAlignmentCenter;

    UIView *headerView       = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, 80)];
    headerLabel.center       = headerView.center;
    [headerView addSubview:headerLabel];

    self.table.tableHeaderView = headerView;
}

// ── PSListController: lettura valore per PSSpecifier ──────────────────────────
//    Chiamato da PreferenceSettings per popolare ogni cella
- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *key = specifier.properties[@"key"];
    if (!key) return nil;

    // Legge dalla cache in-memory (veloce, zero disco)
    id value = _prefs[key];

    // Se non presente, restituisce il default dichiarato nel plist
    if (!value) {
        value = specifier.properties[@"default"];
    }

    return value;
}

// ── PSListController: scrittura valore per PSSpecifier ────────────────────────
//    Chiamato ogni volta che l'utente modifica un controllo
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = specifier.properties[@"key"];
    if (!key) return;

    // Aggiorna cache
    if (value) {
        _prefs[key] = value;
    } else {
        [_prefs removeObjectForKey:key];
    }

    // ── Salvataggio atomico su disco ─────────────────────────────────────────
    //  writeToFile:atomically:YES usa una write+rename: nessuna corruzione
    //  in caso di crash o respring durante la scrittura.
    BOOL success = [_prefs writeToFile:kPrefsPath atomically:YES];
    if (!success) {
        NSLog(@"[SAPPrefs] Errore scrittura plist in %@", kPrefsPath);
        // Tenta di creare la directory se mancante
        NSString *dir = [kPrefsPath stringByDeletingLastPathComponent];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];
        [_prefs writeToFile:kPrefsPath atomically:YES];
    }

    // ── Sincronizza cfprefsd ──────────────────────────────────────────────────
    //  CFPreferencesSetMultiple aggiorna la cache di cfprefsd in modo che
    //  NSUserDefaults e CFPreferencesCopyValue vedano i nuovi valori.
    CFPreferencesSetMultiple(
        (__bridge CFDictionaryRef)_prefs,
        NULL,  // rimuovi nessuna chiave
        (__bridge CFStringRef)kPrefsDomain,
        kCFPreferencesCurrentUser,
        kCFPreferencesAnyHost
    );
    CFPreferencesSynchronize(
        (__bridge CFStringRef)kPrefsDomain,
        kCFPreferencesCurrentUser,
        kCFPreferencesAnyHost
    );

    // ── Notifica Darwin al tweak (aggiornamento live) ─────────────────────────
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFStringRef)kPrefsChangedNotification,
        NULL, NULL, YES
    );
}

// ── Azione: pulsante "Salva e Ricarica SpringBoard" ───────────────────────────
//  Opzionale ma utile per forzare la sincronizzazione
- (void)respring {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Conferma Respring"
                         message:@"SpringBoard verrà riavviato per applicare le modifiche."
                  preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:[UIAlertAction actionWithTitle:@"Annulla"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

    [alert addAction:[UIAlertAction actionWithTitle:@"Riavvia"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *a) {
        // killall springboard via posix: metodo standard nei tweak jailbreak
        pid_t pid;
        const char *args[] = {"killall", "-9", "SpringBoard", NULL};
        posix_spawn(&pid, "/usr/bin/killall", NULL, NULL, (char *const *)args, NULL);
    }]];

    [self presentViewController:alert animated:YES completion:nil];
}

@end
