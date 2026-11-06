# KitKat-API-19-Chroot: Prüfstand

## Auswertung der Kobo-Logs

Die bereitgestellten Logs enthalten den Rootfs-Marker `android-5.0.2_api21`; sie stammen damit von einem Lollipop/API-21-Rootfs und **nicht** von dem hier gewünschten KitKat/API-19-Build. Die Logs dokumentieren dennoch konkrete Fehler im gemeinsamen Startpfad:

- `logcat` zeigt `BatteryService.<init>` mit `NullPointerException` und anschließend `BOOT FAILURE making display ready`. `healthd.txt` meldet `Service batteryproperties: not found`; `bootwatch.log` zeigt `healthd=restarting`. Das belegt, dass der Akku-Properties-Binder-Dienst nicht verfügbar war.
- `logcat` enthält wiederholt `logwrapper: Cannot create parent ptty`. Die angepasste Init hatte `/dev/pts` erzeugt, aber nicht `devpts` gemountet. Netd-/iptables-Aufrufe scheiterten ebenfalls.
- `stages.log` zeigt zusätzlich einen Segfault beim direkten `/system/bin/sh`-Probe. Der spätere normale Start lief aber deutlich weiter bis Zygote und SystemServer; der Probe-Fehler darf daher nicht mit dem dokumentierten Framework-Bootfehler gleichgesetzt werden.

## Umgesetzte Änderungen

1. Die KitKat-Init bindet `devpts` unter dem Android-eigenen `/dev/pts` ein und verlinkt `/dev/ptmx`, damit `logwrapper` und Subprozesse PTYs erhalten.
2. `healthd` ist als nicht-kritischer Dienst hinter `servicemanager` angeordnet und wird erst gestartet, nachdem dessen Status `running` erreicht ist. Damit erhält es die Voraussetzung, `batteryproperties` über Binder zu registrieren.
3. Der Build ist auf Android KitKat/API 19 festgelegt. Das API-19-SDK-Archiv ist mit der SHA-256-Prüfsumme `ca7440cade53d829a8cace857cfad9afaa174c286d1b7a5d139e73cfcfde45d7` gepinnt; Workflow, Paketnamen, Rootfs-Marker und Dokumentation wurden von den veralteten API-21/Lollipop-Angaben bereinigt.

## Verifikation und offene Punkte

Die Hosttests laufen mit **42 Testfällen: 38 erfolgreich, 4 übersprungen**; Shellsyntax, ShellCheck und `git diff --check` sind ebenfalls sauber. Das API-19-Archiv wurde heruntergeladen und die feste Prüfsumme verifiziert. Der komplette SDK-Stagingpfad fand die benötigten KitKat-Dateien, aber die native Kompilierung konnte in dieser ARM64-Sandbox nicht ausgeführt werden: Das historische NDK r10e enthält nur einen x86-64-Hostcompiler (`Exec format error`). GitHub Actions läuft auf x86-64 und muss den Build noch bestätigen.

Der aktuelle Satz Kobo-Logs stammt laut Rootfs-Marker von API 21 und kann die KitKat-Änderungen nicht validieren. Ein echter Libra-Colour-Boot mit API 19 ist ebenfalls noch nicht nachgewiesen. Nach Aktualisierung muss auf dem Gerät `getprop sys.boot_completed` schließlich `1` liefern; außerdem müssen `batteryproperties` im ServiceManager erscheinen und die PTY-/iptables-Fehler verschwinden.

Hosttests starten Android nicht und beweisen keinen Geräteboot. Kein Firmware- oder Kernelimage wird geschrieben. Die zusätzlichen Init-Mounts liegen unter dem Android-Rootfs, sollten aber wegen des auf älteren Kobo-Kerneln verwendeten, weniger isolierten Chroot-Fallbacks auf dem Zielgerät kontrolliert geprüft werden.
