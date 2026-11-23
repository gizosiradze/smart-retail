#!/usr/bin/env python3
"""Rebuilds web/index.html (home page), web/app/index.html (the app) and web/superadmin/index.html from the prototype artifacts.

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


SITE = 'https://smartretail.ge'
TITLE = 'Smart Retail · საცალო ვაჭრობის მართვის სისტემა'
DESC = ('Smart Retail: ბრაუზერში მომუშავე სალარო და მართვის სისტემა ტანსაცმლის, ფეხსაცმლისა და ბავშვთა ნივთების '
        'მაღაზიებისთვის. მარაგი ზომის დონეზე, რამდენიმე ფილიალი, დაბრუნება და ზუსტი ციფრები ლარში.')


def seo_home(home: str) -> str:
    """Search and social tags for the home page. The text comes from the page itself, so it cannot drift."""
    import html, json
    faq = re.findall(r'<details><summary>(.*?)</summary><p>(.*?)</p>', home)
    lead = re.search(r'<p class="lead">(.*?)</p>', home).group(1)
    h1 = re.search(r'<h1 class="lp-ser">(.*?)</h1>', home).group(1)
    ld = [
        {'@context': 'https://schema.org', '@type': 'Organization', 'name': 'Smart Retail', 'url': SITE + '/',
         'logo': SITE + '/icons/icon-512.png', 'email': 'info@smartretail.ge'},
        {'@context': 'https://schema.org', '@type': 'SoftwareApplication', 'name': 'Smart Retail',
         'applicationCategory': 'BusinessApplication', 'operatingSystem': 'Web', 'inLanguage': 'ka',
         'description': DESC, 'url': SITE + '/'},
        {'@context': 'https://schema.org', '@type': 'FAQPage', 'mainEntity': [
            {'@type': 'Question', 'name': html.unescape(q),
             'acceptedAnswer': {'@type': 'Answer', 'text': html.unescape(a)}} for q, a in faq]},
    ]
    head = (f'<meta name="description" content="{html.escape(DESC)}">'
            f'<link rel="canonical" href="{SITE}/">'
            '<meta name="theme-color" content="#6d1a2e">'
            '<meta property="og:type" content="website"><meta property="og:site_name" content="Smart Retail">'
            f'<meta property="og:locale" content="ka_GE"><meta property="og:url" content="{SITE}/">'
            f'<meta property="og:title" content="{html.escape(TITLE)}"><meta property="og:description" content="{html.escape(DESC)}">'
            f'<meta property="og:image" content="{SITE}/icons/og-image.png">'
            '<meta property="og:image:width" content="1200"><meta property="og:image:height" content="630">'
            '<meta name="twitter:card" content="summary_large_image">'
            f'<meta name="twitter:title" content="{html.escape(TITLE)}"><meta name="twitter:description" content="{html.escape(DESC)}">'
            f'<meta name="twitter:image" content="{SITE}/icons/og-image.png">'
            + ''.join(f'<script type="application/ld+json">{json.dumps(x, ensure_ascii=False)}</script>' for x in ld))
    home = patch(home, 'seo head', f'<title>{TITLE}</title>', f'<title>{TITLE}</title>' + head)
    # visible only without JavaScript (crawlers, link previews): the page text the script would draw
    ns = ('<noscript><main><h1>' + h1 + '</h1><p>' + lead + '</p><h2>ხშირი კითხვები</h2>'
          + ''.join(f'<h3>{q}</h3><p>{a}</p>' for q, a in faq)
          + '<p>info@smartretail.ge</p></main></noscript>')
    return patch(home, 'seo noscript', '<body><div id="app"></div>', '<body><div id="app"></div>' + ns)


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
    s = patch(s, 'scripts', '</template>\n<script>\n', '</template>\n<script src="../config.js"></script>\n<script src="../js/sr.js"></script>\n<script src="../js/sr-notify.js"></script>\n<script>\n')

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
    for cls in ('lgx', 'lgo'):
        s = patch(s, 'logout ' + cls, f'<button class="{cls}" onclick="U=null;cart=[];render()">გასვლა</button>',
                  f'<button class="{cls}" onclick="if(window.SR&&SR.on)SR.logout();else{{U=null;cart=[];render()}}">გასვლა</button>')

    # 4b. notifications live in Management (Employees -> Notifications, js/sr-notify.js), not in the header
    s = patch(s, 'notifications tab', "['r','როლები და უფლებები'],['x',", "['r','როლები და უფლებები'],['n','შეტყობინებები'],['x',")
    s = patch(s, 'notifications page', "emT=='r'?emRoles():", "emT=='n'?ntPage():emT=='r'?emRoles():")

    # 5. per-screen loading: wait for this screen's data, then refresh it in the background.
    #    While a screen's data is still loading, the header and menu stay on screen (only <main> waits).
    s = patch(s, 'render hook', "const t=navFor();view=view&&t.some(x=>x[0]==view)?view:t[0][0];",
              "const t=navFor();if(!view){const h=location.pathname.replace(/^\\/app\\/?/,'');if(t.some(x=>x[0]==h))view=h}view=view&&t.some(x=>x[0]==view)?view:t[0][0];if(location.hash!=='#sa'&&location.pathname!=='/app/'+view)history[/^\\/app\\/?$/.test(location.pathname)?'replaceState':'pushState'](null,'','/app/'+view);"
              "window.SRLD=0;if(window.SR&&SR.on){if(!SR.ready(view)){SRLD=1;if(!SR.loadError())SR.ensure(view).then(render)}else SR.touch(view)}")
    # browser Back/Forward: each page has its own address (/app/<view>; Cloudflare rewrites it to the app, see web/_redirects)
    s = patch(s, 'popstate', "let sxM=innerWidth<=900;", "addEventListener('popstate',()=>{if(!U)return;const v=location.pathname.replace(/^\\/app\\/?/,'');if(v&&v!=view&&navFor().some(x=>x[0]==v)){view=v;np=0;render()}});let sxM=innerWidth<=900;")
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

    # 6b. cashier (wide screens): the cart and the search/tabs are frozen; only the product list scrolls.
    #     The two-column block gets exactly the height left on the screen (--gh, measured by srFit), so the page itself never scrolls.
    css = ("@media(min-width:761px){.g2:has(>#cart){height:calc(100vh - 300px);height:var(--gh,calc(100dvh - 300px));align-items:stretch}"
           ".g2:has(>#cart)>#cart{position:static;align-self:start;max-height:100%;display:flex;flex-direction:column}"
           "#cart .cth{flex:none}#cart .cbd{flex:1 1 auto;min-height:0;overflow-y:auto;overscroll-behavior:contain}"
           "#cart .cil{max-height:none;overflow:visible;margin:0;padding:0}#cart #paybtn{position:sticky;bottom:0;z-index:1}"
           ".g2:has(>#cart)>section:not(#cart){display:flex;flex-direction:column;min-height:0;height:100%}"
           ".g2:has(>#cart)>section:not(#cart)>#sc,.g2:has(>#cart)>section:not(#cart)>#ptabs{flex:none}"
           ".g2:has(>#cart)>section:not(#cart)>#pl{flex:1 1 auto;min-height:0;overflow-y:auto;align-content:start;overscroll-behavior:contain;padding-bottom:4px}}")
    a = '#sc{padding:12px 16px;font-size:15px;border-radius:12px}#cart .pri{padding:13px;font-size:15px}'
    s = patch(s, 'cart pinned', a, a + '\n' + css)
    fit = ("<script>(function(){function f(){var c=document.querySelector('.g2>#cart');if(!c)return;var t=c.parentElement.getBoundingClientRect().top+scrollY;"
           "document.documentElement.style.setProperty('--gh',Math.max(320,innerHeight-t-56)+'px')}var q=0;"
           "function g(){cancelAnimationFrame(q);q=requestAnimationFrame(f)}"
           "addEventListener('DOMContentLoaded',function(){new MutationObserver(g).observe(document.getElementById('app'),{childList:true,subtree:true});g()});"
           "addEventListener('resize',g)})()</script>\n")
    s = patch(s, 'cart height script', '<script src="../config.js"></script>\n', '<script src="../config.js"></script>\n' + fit)

    # 7a. home page (web/index.html): the prototype's own landing page, "sign in" leads to /app/
    home = patch(s, 'home sign in', 'function lpLogin(){LPG=false;render();scrollTo(0,0);', "function lpLogin(){location.href='app/';return;")
    home = home.replace('src="../config.js"', 'src="config.js"').replace('src="../js/sr.js"', 'src="js/sr.js"').replace('src="../js/sr-notify.js"', 'src="js/sr-notify.js"')

    # 7b. the app itself (web/app/index.html) opens straight on the login form; the landing page is a separate address
    s = patch(s, 'app opens on login', 'let LPG=true;', 'let LPG=false;')
    s = patch(s, 'app back link', 'onclick="LPG=1;render();scrollTo(0,0)">← მთავარი გვერდი', "onclick=\"location.href='../'\">← მთავარი გვერდი")

    # 7c. installable app (PWA): manifest, icons, service worker (manifest and service worker live in web/app/, icons in web/icons/)
    s = patch(s, 'pwa head', '<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">',
              '<base href="/app/"><meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">'
              '<meta name="theme-color" content="#6d1a2e"><meta name="mobile-web-app-capable" content="yes">'
              '<meta name="apple-mobile-web-app-capable" content="yes"><meta name="apple-mobile-web-app-title" content="Smart Retail">'
              '<link rel="manifest" href="manifest.webmanifest"><link rel="apple-touch-icon" href="../icons/apple-touch-icon.png">')
    s = patch(s, 'pwa sw', '<script src="../config.js"></script>\n',
              '<script src="../config.js"></script>\n'
              "<script>if('serviceWorker' in navigator&&location.protocol!=='file:')addEventListener('load',()=>navigator.serviceWorker.register('sw.js').catch(()=>{}))</script>\n")


    # menu and footer items become real links (crawlers follow <a href>, not onclick); same look as the buttons they replace
    home, n = re.subn(r'<button onclick="lpGo\(\'(lp-[a-z0-9]+)\'\)">([^<]*)</button>',
                      r'<a href="#\1" onclick="lpGo(this.hash.slice(1));return false">\2</a>', home)
    if n != 12:
        sys.exit(f"home links: expected 12 lpGo buttons, found {n}")
    home = patch(home, 'home login link 1', '<button onclick="lpLogin()" style="color:var(--wine);font-weight:600">სისტემაში შესვლა</button>',
                 '<a href="/app/" onclick="lpLogin();return false" style="color:var(--wine);font-weight:600">სისტემაში შესვლა</a>')
    home = patch(home, 'home login link 2', '<li><button onclick="lpLogin()">შესვლა</button></li>',
                 '<li><a href="/app/" onclick="lpLogin();return false">შესვლა</a></li>')
    home = patch(home, 'home link css', '</style></head><body>',
                 '.lp-nav a,.lp-mn a,.lp-ft li a{font:inherit;cursor:pointer;text-decoration:none;text-align:center;color:inherit}'
                 '.lp-nav a{padding:8px 13px;border-radius:10px;font-size:15px;color:#4a3f43;transition:background .15s,color .15s}'
                 '.lp-nav a:hover{background:var(--soft);color:var(--ink)}'
                 '.lp-ft li a{display:inline-block;color:#c9bec2;transition:color .15s}.lp-ft li a:hover{color:#fff}'
                 '@media(max-width:860px){.lp-mn a{display:block;width:100%;text-align:left;padding:14px 4px;font-size:17px;border-bottom:1px solid #f1eaec}}'
                 '</style></head><body>')

    # speed: Google Fonts CSS no longer blocks the first paint (display=swap shows text at once), earlier connection to the font host
    fonts = re.search(r'<link href="(https://fonts\.googleapis\.com/css2\?[^"]*)" rel="stylesheet">', home)
    if not fonts:
        sys.exit('home fonts: Google Fonts link not found')
    furl = fonts.group(1)
    home = home.replace(fonts.group(0),
        '<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>'
        f'<link href="{furl}" rel="stylesheet" media="print" onload="this.media=\'all\'">'
        f'<noscript><link href="{furl}" rel="stylesheet"></noscript>')
    home = seo_home(home)
    (ROOT / 'web/index.html').write_text(home)
    s = patch(s, 'app noindex', '<title>' + TITLE + '</title>', '<meta name="robots" content="noindex,nofollow"><title>' + TITLE + '</title>')
    (ROOT / 'web/app').mkdir(exist_ok=True)
    (ROOT / 'web/app/index.html').write_text(s)
    print('web/index.html and web/app/index.html written')


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
    s = patch(s, 'sa noindex', '<title>RMS · სუპერ ადმინი</title>', '<meta name="robots" content="noindex,nofollow"><title>RMS · სუპერ ადმინი</title>')
    (ROOT / 'web/superadmin/index.html').write_text(s)
    print('web/superadmin/index.html written')


if __name__ == '__main__':
    build_app()
    build_superadmin()
