#!/usr/bin/env python3
# Prüft, ob jeder Oberflächentext L(@"…") im Code eine Übersetzung in en.lproj/Localizable.strings hat.
import re, sys, os
os.chdir(os.path.dirname(os.path.abspath(__file__)))
lit = re.compile(r'L\(@"((?:[^"\\\n]|\\.)*)"((?:\s*"(?:[^"\\\n]|\\.)*")*)\)')
keys = []
for f in ('main.m', 'MainWindow.m', 'Calibration.m', 'JumpBassRevived.h'):
    for m in lit.finditer(open(f).read()):
        k = m.group(1) + ''.join(re.findall(r'"((?:[^"\\\n]|\\.)*)"', m.group(2)))
        if k not in keys: keys.append(k)
known = set(re.findall(r'^"((?:[^"\\\n]|\\.)*)" = ', open('en.lproj/Localizable.strings').read(), re.M))
missing = [k for k in keys if k not in known]
unused = [k for k in known if k not in keys]
for k in missing: print('fehlt:  ', k)
for k in unused: print('unbenutzt:', k)
sys.exit(1 if missing else 0)
