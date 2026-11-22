#!/usr/bin/env python3
"""Rebuilds web/index.html and web/superadmin/index.html from the prototype artifacts.

The prototypes stay the design source of truth on claude.ai. When a new prototype version is exported
to prototype/app.html and prototype/superadmin.html, run:

    python3 scripts/build-web-from-prototype.py

Each patch must match exactly once; if the prototype changed in one of these places the script stops
and names the patch, so it can be updated instead of silently producing a broken app.
"""
import pathlib, re, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent


def patch(src: str, name: str, old: str, new: str) -> str:
    n = src.count(old)
    if n != 1:
        sys.exit(f"patch '{name}': expected 1 match, found {n}")
    return src.replace(old, new)


def strip_host_wrapper(s: str) -> str:
    # claude.ai stores artifacts inside its own small <html> shell; keep only the page itself
    i = s.find('<!doctype html><html lang="ka">')
    if i > 0:
        s = s[i:]
    s = s.rstrip()
    while s.endswith('</body></html>\n\n</body></html>') or s.endswith('</body></html>\n</body></html>'):
        s = s[: s.rfind('</body></html>')].rstrip()
    return s + '\n'


def build_app() -> None:
    s = strip_host_wrapper((ROOT / 'prototype/app.html').read_text())

    # 1. config + data layer load before the app script
    s = patch(s, 'scripts', '</template>\n<script>\n', '</template>\n<script src="config.js"></script>\n<script src="js/sr.js"></script>\n<script>\n')

    # 2. save(): Supabase instead of localStorage (the landing-page demo iframe keeps its in-memory copy)
    s = patch(s, 'save',
              "if(window.EMB){D=JSON.parse(SNAP);try{parent.postMessage({lwb:1},'*')}catch(e){}return}try{localStorage.setItem('rms1',JSON.stringify(D));SVOK=1}catch(e){SVOK=0}};",
              "if(window.EMB){D=JSON.parse(SNAP);try{parent.postMessage({lwb:1},'*')}catch(e){}return}if(window.SR&&SR.on){SR.save();return}try{localStorage.setItem('rms1',JSON.stringify(D));SVOK=1}catch(e){SVOK=0}};")

    # 3. login(): server check; the old in-browser check remains only for the offline prototype mode
    s = patch(s, 'login', 'function login(){const s=$(\'#ls\').value.trim()',
              "async function login(){if(window.SR&&SR.on){const e=$('#le'),b=document.querySelector('.lg .pri');e.textContent='';if(b)b.disabled=true;"
              "try{await SR.login($('#ls').value.trim(),$('#lu').value.trim(),$('#lp').value)}catch(x){e.textContent=SR.msg(x)}finally{if(b)b.disabled=false}return}"
              "loginLocal()}\nfunction loginLocal(){const s=$('#ls').value.trim()")
    s = patch(s, 'demo hint', '<small class="m">დემო: admin / kasa1 / kasa2 / sawyobi · პაროლი 1234</small>',
              "${window.SR_CONFIG&&SR_CONFIG.demoHint?`<small class=\"m\">${SR_CONFIG.demoHint}</small>`:''}")
    s = patch(s, 'login placeholder', 'placeholder="მაღაზიის სახელი" autocomplete="off"',
              'placeholder="მაღაზიის სახელი (ლათინურად)" autocomplete="organization" autocapitalize="off"')

    # 4. logout
    s = patch(s, 'logout', '<button onclick="U=null;cart=[];render()">გასვლა</button>',
              '<button onclick="if(window.SR&&SR.on)SR.logout();else{U=null;cart=[];render()}">გასვლა</button>')

    # 5. per-screen loading: wait for this screen's data, then refresh it in the background.
    #    While a screen's data is still loading, the header and menu stay on screen (only <main> waits).
    s = patch(s, 'render hook', "const t=navFor();view=view&&t.some(x=>x[0]==view)?view:t[0][0];",
              "const t=navFor();view=view&&t.some(x=>x[0]==view)?view:t[0][0];"
              "window.SRLD=0;if(window.SR&&SR.on){if(!SR.ready(view)){SRLD=1;if(!SR.loadError())SR.ensure(view).then(render)}else SR.touch(view)}")
    s = patch(s, 'render main', "${V[view]()}</main>", "${window.SRLD?SR.mainLoadingHtml():V[view]()}</main>")

    # 6. startup: keep the prototype's own start-up for the demo/offline mode; in Supabase mode the same
    #    defaults run after the data has loaded (srNormalize) and nothing is seeded
    start = s.index('load();D.sh=D.sh||[];')
    end = s.index('if(window.EMB){SNAP=JSON.stringify(D);', start)
    tail_end = s.index('else{save();render()}', end) + len('else{save();render()}')
    line = s[start:tail_end]
    override = "{const vs=V.sale,vr=V.rx;V.sale=()=>U.role=='pos'&&!zhCur()?zhPanel():vs();V.rx=()=>U.role=='pos'&&!zhCur()?zhPanel():vr()}"
    if line.count(override) != 1:
        sys.exit('patch startup: shift override not found')
    body = line.replace(override, '')
    seeders = 'seedSup();seedCu();seedUs();seedSg();seedWr();seedEx();'
    if body.count(seeders) != 1 or body.count('seedTr();jrSnap();jrSeed();') != 1:
        sys.exit('patch startup: seeders not found')
    norm = body[len('load();'):body.index("if(!D.csd){")]
    after_csd = body[body.index("D.p.forEach(p=>{if(p.cost==null)"):body.index(seeders)]
    rcv = "(D.us||[]).forEach(u=>{if(u.role=='cashier'&&u.perms&&u.perms.rcv===undefined)u.perms.rcv=1});"
    if body.count(rcv) != 1:
        sys.exit('patch startup: rcv default not found')
    new = (override + "\n"
           "function srNormalize(){" + norm + after_csd + rcv + "trDocs&&trDocs();jrSnap()}\n"
           "if(window.SR&&SR.on){SR.boot()}else{" + body + "}")
    s = s[:start] + new + s[tail_end:]

    # 7. installable app (PWA): manifest, icons, service worker (files live in web/, see web/sw.js)
    s = patch(s, 'pwa head', '<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">',
              '<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">'
              '<meta name="theme-color" content="#6d1a2e"><meta name="mobile-web-app-capable" content="yes">'
              '<meta name="apple-mobile-web-app-capable" content="yes"><meta name="apple-mobile-web-app-title" content="Smart Retail">'
              '<link rel="manifest" href="manifest.webmanifest"><link rel="apple-touch-icon" href="icons/apple-touch-icon.png">')
    s = patch(s, 'pwa sw', '<script src="config.js"></script>\n',
              '<script src="config.js"></script>\n'
              "<script>if('serviceWorker' in navigator&&location.protocol!=='file:')addEventListener('load',()=>navigator.serviceWorker.register('sw.js').catch(()=>{}))</script>\n")

    (ROOT / 'web/index.html').write_text(s)
    print('web/index.html written')


def build_superadmin() -> None:
    s = strip_host_wrapper((ROOT / 'prototype/superadmin.html').read_text())
    s = patch(s, 'sa scripts', '<script>\n/* ================= helpers ================= */',
              '<script src="../config.js"></script>\n'
              '<script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.45.4/dist/umd/supabase.js"></script>\n'
              '<script src="../js/sr-platform.js"></script>\n<script>\n/* ================= helpers ================= */')
    # login / logout through Supabase Auth with an authenticator app
    s = patch(s, 'sa login', "function login(){if(!$('#lu').value",
              "function login(){if(window.SRP&&SRP.on)return SRP.login();loginLocal()}\nfunction loginLocal(){if(!$('#lu').value")
    s = patch(s, 'sa logout', "function logout(){log('სუპერ ადმინი გავიდა');go('login')}",
              "function logout(){log('სუპერ ადმინი გავიდა');if(window.SRP&&SRP.on){SRP.logout();return}go('login')}")
    s = patch(s, 'sa login view', "function loginView(){", "function loginView(){if(window.SRP&&SRP.on)return SRP.loginView();")
    # data: Supabase instead of localStorage
    s = patch(s, 'sa save', "function save(){try{localStorage.setItem(K,JSON.stringify(D))}catch(e){}}",
              "function save(){if(window.SRP&&SRP.on){SRP.save();return}try{localStorage.setItem(K,JSON.stringify(D))}catch(e){}}")
    # registration and password reset happen on the server, which creates the real accounts
    s = patch(s, 'sa register', "function doRegister(){", "function doRegister(){if(window.SRP&&SRP.on)return SRP.register();doRegisterLocal()}\nfunction doRegisterLocal(){")
    s = patch(s, 'sa reset', "function resetPass(id,i){", "function resetPass(id,i){if(window.SRP&&SRP.on)return SRP.resetPass(id,i);resetPassLocal(id,i)}\nfunction resetPassLocal(id,i){")
    # real numbers instead of the random demo metrics
    s = patch(s, 'sa metrics', "function metrics(s){", "function metrics(s){if(window.SRP&&SRP.on)return SRP.metrics(s);return metricsDemo(s)}\nfunction metricsDemo(s){")
    # the store's real dashboard in a new tab, read-only (prototype only explains what it would do)
    s = patch(s, 'sa open as store', "function openAsStore(id){", "function openAsStore(id){if(window.SRP&&SRP.on)return SRP.openAsStore(id);openAsStoreLocal(id)}\nfunction openAsStoreLocal(id){")
    s = patch(s, 'sa reset demo', "function resetDemo(", "function resetDemo(){if(window.SRP&&SRP.on){toast('რეალურ სისტემაში დემოს აღდგენა გამორთულია');return}resetDemoLocal()}\nfunction resetDemoLocal(")
    s = patch(s, 'sa boot', "D=load();\nrender();", "if(window.SRP&&SRP.on){SRP.boot()}else{D=load();render()}")
    (ROOT / 'web/superadmin/index.html').write_text(s)
    print('web/superadmin/index.html written')


if __name__ == '__main__':
    build_app()
    build_superadmin()
