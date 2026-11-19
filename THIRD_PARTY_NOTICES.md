# THIRD_PARTY_NOTICES

**Запрет2 Easy** — независимая сборка. Она **не является** официальным проектом
bol-van (zapret2) или Flowseal (zapret-discord-youtube) и не поддерживается ими.
Авторы оригинальных проектов не несут ответственности за эту сборку.

Сборка распространяется бесплатно, без гарантий, «как есть».

---

## Лицензия проекта

Код оболочки (скрипты PowerShell, `service.bat`), пресеты в синтаксисе nfqws2,
собственные списки и документация распространяются под лицензией **MIT**
(полный текст — в файле `LICENSE`).

Сторонние компоненты остаются под своими лицензиями и приведены ниже.

## Атрибуция — кратко

| Автор / проект | Что взято | Лицензия |
|---|---|---|
| **bol-van** — [zapret2](https://github.com/bol-van/zapret2) v1.0.7 | движок `winws2.exe`, стандартные Lua-библиотеки, блобы фейков, примеры фильтров WinDivert | MIT |
| **Flowseal** — [zapret-discord-youtube](https://github.com/Flowseal/zapret-discord-youtube) 1.10.4 | идеи пресетов и структуры меню, списки доменов/IP, часть блобов | MIT |
| **basil00** — [WinDivert](https://reqrypt.org/windivert.html) 2.2 | `WinDivert.dll`, `WinDivert64.sys` | LGPL v3 |
| **Cygwin** | `cygwin1.dll` 3.4.10 | LGPL v3 |
| **Lua / LuaJIT** | интерпретатор внутри `winws2.exe` | MIT |

Движок и стандартные Lua-библиотеки **не изменялись**: их SHA256 сверены с
официальным архивом zapret2 v1.0.7.

---

## 1. zapret2 — движок

- Автор: **bol-van**
- Источник: <https://github.com/bol-van/zapret2>, релиз **v1.0.7**
- Лицензия: **MIT**, Copyright (c) 2016-2026 bol-van

### Что взято из zapret2

| Что | Файлы | Изменения |
|---|---|---|
| Движок Windows x64 | `bin\winws2.exe` | **не изменялся**, SHA256 сверен с архивом |
| Рантайм | `bin\cygwin1.dll`, `bin\WinDivert.dll`, `bin\WinDivert64.sys` | не изменялись |
| Утилиты | `bin\mdig.exe`, `bin\ip2net.exe`, `bin\killall.exe` | не изменялись |
| Стандартные Lua-библиотеки | `lua\zapret-lib.lua`, `zapret-antidpi.lua`, `zapret-auto.lua`, `zapret-obfs.lua`, `zapret-tests.lua`, `zapret-pcap.lua` | **не изменялись**, побайтово равны файлам архива |
| Блобы фейков | `fake\` (46 файлов) | не изменялись |
| Примеры фильтров WinDivert | `bin\windivert.filter\windivert_part.*.txt` (5 файлов) | не изменялись |
| Документация | использовалась как источник истины при портировании | — |

Собственный файл сборки в этой папке — только
`bin\windivert.filter\windivert_part.quic_longheader_in.txt`.

### Текст лицензии MIT (zapret2)

```
MIT License

Copyright (c) 2016-2026 bol-van

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

## 2. zapret-discord-youtube — данные и UX

- Автор: **Flowseal**
- Источник: <https://github.com/Flowseal/zapret-discord-youtube>, версия **1.10.4**
- Лицензия: **MIT** (по заявлению проекта). В распространяемом архиве 1.10.4
  файла лицензии нет, поэтому ниже приведён стандартный текст MIT с указанием
  автора; при обнаружении расхождений с оригиналом приоритет имеет оригинал.

### Что взято из сборки Flowseal

| Что | Где используется | Изменения |
|---|---|---|
| 22 пресета (`.bat`) | `presets\*.txt` | **синтаксис переписан** с nfqws1 на nfqws2, стратегии сохранены; соответствие имён — в `PRESETS.md` |
| Списки доменов и IP | `lists\list-general.txt`, `list-google.txt`, `list-exclude.txt`, `ipset-exclude.txt`, `ipset-all.txt` | не изменялись (ipset — снапшот из `ipset-all.txt.backup`) |
| Блобы фейков (20 уникальных) | `fake\` | не изменялись |
| Идеи структуры меню и диагностики | `core\Menu.ps1`, `core\Diagnostics.ps1` | **код написан заново на PowerShell**, батники Flowseal не используются |
| Список проверок конфликтующего ПО | `core\Diagnostics.ps1` | переработан |

Батники, служба и движок `winws.exe` из сборки Flowseal **не поставляются**.

### Текст лицензии MIT (Flowseal)

```
MIT License

Copyright (c) Flowseal

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

## 3. WinDivert — драйвер и библиотека

- Автор: **basil00** (проект reqrypt.org)
- Источник: <https://reqrypt.org/windivert.html>, версия **2.2**
- Лицензия: **LGPL v3** (также доступна коммерческая лицензия у автора)
- Файлы в сборке: `bin\WinDivert.dll`, `bin\WinDivert64.sys` — **не изменялись**,
  взяты из официального архива zapret2 v1.0.7.

WinDivert — это драйвер режима ядра, который перехватывает сетевые пакеты.
Именно он вызывает срабатывания антивирусов («risk tool»). Это ожидаемо:
инструмент легитимный, но по характеру работы похож на хакерский.

Исходный код WinDivert доступен по адресу выше; в соответствии с LGPL v3 вы
вправе заменить эти файлы на свою сборку библиотеки.

---

## 4. Cygwin

- Автор: **Red Hat / проект Cygwin**
- Источник: <https://cygwin.com>
- Лицензия: **LGPL v3** (для `cygwin1.dll`; отдельные части — GPL)
- Файл в сборке: `bin\cygwin1.dll` версии **3.4.10**, не изменялся, взят из
  официального архива zapret2 v1.0.7.

`winws2.exe` собран под Cygwin и требует эту библиотеку рядом с собой при
standalone-запуске. Исходный код Cygwin доступен по адресу выше.

---

## 5. Lua

Движок `winws2.exe` статически содержит интерпретатор Lua (Lua 5.4 / LuaJIT в
зависимости от платформы) — лицензия **MIT**, Copyright (c) Lua.org, PUC-Rio и
авторы LuaJIT. Отдельных файлов в сборке нет, код находится внутри `winws2.exe`.

---

## 6. Что в этой сборке написано нами

Всё, что не перечислено выше, написано для этой сборки:

- `service.bat`, `core\*.ps1` — меню, служба, диагностика, тесты, работа со списками;
- `presets\AUTO.txt` — пресет автоматической смены стратегий;
- `presets\*.txt` — переписанные в синтаксис nfqws2 пресеты (по данным Flowseal);
- `lists\list-youtube.txt`, `lists\*-user.txt` — наши списки;
- `bin\windivert.filter\windivert_part.quic_longheader_in.txt` — наш фильтр;
- `README.md`, `PRESETS.md`, этот файл.

Эти файлы можно свободно использовать и изменять.

---

## 7. Отказ от ответственности

Сборка изменяет обработку сетевого трафика на вашем компьютере и устанавливает
драйвер режима ядра. Используйте на свой риск и в соответствии с законами вашей
страны. Автор сборки не несёт ответственности за последствия использования,
за блокировки со стороны провайдера и за возможные конфликты с антивирусами
и другим сетевым ПО.
