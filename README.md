
# 💊 Farmácia — App Flutter + API FastAPI

Sistema de PDV (ponto de venda) para farmácia: catálogo, controle de estoque
e histórico de vendas. App em **Flutter** conversando com uma **API FastAPI**
via HTTP, com persistência em JSON no servidor.

---

## 📁 Estrutura do projeto

```
.
├── dev.sh                    # script que sobe tudo (API + app)
├── README.md
├── api/
│   ├── farmacia_api.py       # API FastAPI (arquivo único)
│   ├── medicamentos.json     # criado na 1ª execução
│   └── vendas.json           # criado na 1ª execução
└── app/
    ├── pubspec.yaml
    └── lib/
        └── main.dart         # app Flutter (arquivo único)
```

---

## ✅ Pré-requisitos

- **Python 3.10+** com `fastapi` e `uvicorn`
- **Flutter SDK** (canal stable)
- **Android SDK** + `adb` no PATH (para rodar em emulador ou device físico)
- Um dispositivo Android conectado por USB **ou** emulador aberto

Instalação das dependências Python:

```bash
pip install fastapi uvicorn
```

---

## 🚀 Como rodar (o jeito fácil)

O projeto vem com o `dev.sh`, que faz o trabalho chato:

1. Sobe a API em background (`uvicorn --reload`)
2. Configura `adb reverse` para o celular/emulador enxergar `localhost:8000`
3. Roda o Flutter com a URL da API já injetada
4. Ao sair (Ctrl+C), mata a API e remove o `adb reverse`

```bash
chmod +x dev.sh   # só na primeira vez
./dev.sh
```

Saída esperada:

```
INFO:     Uvicorn running on http://127.0.0.1:8000 (Press CTRL+C to quit)
INFO:     Started reloader process [...]
flutter: ...
```

### Por que `adb reverse`?

O celular **não enxerga** o `localhost` do seu PC — pra ele, `localhost`
significa *ele mesmo*. O `adb reverse tcp:8000 tcp:8000` cria um túnel:
tudo que o app pedir pra `127.0.0.1:8000` no dispositivo é encaminhado para
`8000` na sua máquina. Isso funciona tanto em emulador quanto em device físico
via USB, e dispensa mexer em IP/porta ou CORS.

> 💡 **Não precisa de CORS** porque as chamadas saem do app nativo (Dart VM),
> não do navegador.

---

## 🔧 Rodando manualmente (caso queira controle fino)

Terminal 1 — API:

```bash
uvicorn farmacia_api:app --reload --app-dir api
```

Documentação interativa: <http://localhost:8000/docs>

Terminal 2 — App:

```bash
adb reverse tcp:8000 tcp:8000
cd app
flutter run --dart-define=API_BASE_URL=http://127.0.0.1:8000
```

### URLs por plataforma

| Plataforma               | `API_BASE_URL` padrão        |
|--------------------------|------------------------------|
| Android (emulador)       | `http://10.0.2.2:8000`       |
| Android (device + `adb reverse`) | `http://127.0.0.1:8000` |
| iOS simulator / desktop  | `http://localhost:8000`      |
| Web                      | `http://localhost:8000` ⚠️    |

O app detecta sozinho o padrão, mas você pode sobrescrever com
`--dart-define=API_BASE_URL=...` sempre que precisar.

⚠️ Em **Flutter Web**, chamar a API exige CORS habilitado no backend.
Como o projeto prioriza mobile (`adb reverse`), a API **não** liga CORS
por padrão.

---

## 🌐 API — Endpoints principais

Todos os dados persistem em `medicamentos.json` e `vendas.json`, ao lado do
`farmacia_api.py`. Apagar esses arquivos reseta a base.

### Medicamentos

| Método   | Rota                                | Descrição                          |
|----------|-------------------------------------|------------------------------------|
| `GET`    | `/medicamentos`                     | Lista paginada + filtros           |
| `GET`    | `/medicamentos/{id}`                | Detalhe                            |
| `POST`   | `/medicamentos`                     | Cadastra                           |
| `PUT`    | `/medicamentos/{id}`                | Atualiza                           |
| `DELETE` | `/medicamentos/{id}`                | Remove                             |
| `PATCH`  | `/medicamentos/{id}/estoque`        | Ajuste manual (entrada/saída)      |
| `GET`    | `/medicamentos/buscar?q=...`        | Busca por nome/princípio/lab       |
| `GET`    | `/medicamentos/estoque-baixo`       | Estoque ≤ 30                       |
| `GET`    | `/categorias`                       | Categorias + contagem              |
| `GET`    | `/estatisticas`                     | Resumo geral                       |

### Vendas

| Método | Rota                     | Descrição                                       |
|--------|--------------------------|-------------------------------------------------|
| `GET`  | `/vendas`                | Lista (mais recentes primeiro)                  |
| `GET`  | `/vendas/{id}`           | Detalhe                                         |
| `POST` | `/vendas`                | **Cria venda (atômica)**                        |
| `POST` | `/vendas/{id}/cancelar`  | Cancela e **devolve ao estoque**                |

#### Por que a venda é atômica?

`POST /vendas` faz, em sequência, dentro de uma única chamada:

1. Valida estoque de **todos** os itens
2. Calcula subtotal, desconto e total
3. Baixa o estoque
4. Grava a venda em `vendas.json`

Se qualquer passo falhar (ex.: item sem estoque), nada é alterado — nem
estoque, nem arquivo de vendas. Isso evita estado inconsistente tipo
"venda gravada mas estoque não baixado" ou vice-versa.

---

## 🏗️ Arquitetura (rápida)

- **Servidor = fonte da verdade**. Vendas, estoque e catálogo vivem na API.
- **App é stateless por design**: não guarda nada em `SharedPreferences`.
  Fechar o app, reinstalar ou trocar de dispositivo não perde histórico.
- **Três stores** no app via `ChangeNotifier`:
  - `catalog` — catálogo de medicamentos
  - `carrinho` — itens em edição (esse sim fica só em memória)
  - `vendasStore` — histórico vindo do servidor
- **Sem CORS** porque o alvo é mobile com `adb reverse`.

---

## 🧪 Testando a API direto (sem o app)

```bash
# health check
curl http://localhost:8000/

# listar medicamentos
curl http://localhost:8000/medicamentos

# criar uma venda (2× Dipirona, 10% off, Pix)
curl -X POST http://localhost:8000/vendas \
  -H "Content-Type: application/json" \
  -d '{
        "itens": [{"medicamento_id": 1, "quantidade": 2}],
        "pagamento": "pix",
        "desconto_pct": 10
      }'

# listar vendas
curl http://localhost:8000/vendas

# cancelar a venda #1 (devolve ao estoque)
curl -X POST http://localhost:8000/vendas/1/cancelar

# conferir que o estoque voltou
curl http://localhost:8000/medicamentos/1
```

Ou abra o Swagger em <http://localhost:8000/docs> e teste tudo na UI.

---

## 🧹 Resetar os dados

```bash
rm api/medicamentos.json api/vendas.json
```

Na próxima execução, a API recria `medicamentos.json` com 10 medicamentos
de exemplo e `vendas.json` vazio.

---

## 🐛 Problemas comuns

| Sintoma | Causa provável | Solução |
|---|---|---|
| App mostra "Erro de conexão" | API não está rodando | Rodar `./dev.sh` ou subir `uvicorn` manualmente |
| App conecta no emulador mas não no device | Faltou `adb reverse` | `adb reverse tcp:8000 tcp:8000` |
| `adb: command not found` | `adb` fora do PATH | Adicionar `$ANDROID_SDK/platform-tools` ao PATH |
| `dev.sh` reclama do Python | Faltam dependências | `pip install fastapi uvicorn` |
| Alterações na API não refletem | `--reload` pode ter caído | Reiniciar `./dev.sh` |
| Primeira execução lenta | Flutter baixando Gradle/deps | Normal, só na 1ª vez |

---

## 📝 Notas

- O app **não usa `shared_preferences`** — se você viu essa dependência em
  algum lugar, já foi removida. Tudo vem da API.
- `dev.sh` mata a API e remove o `adb reverse` automaticamente ao sair
  (via `trap ... EXIT INT TERM`), então não fica processo órfão.
- Os arquivos JSON são para simplicidade. Em produção, trocaria por
  SQLite/Postgres sem mudar os contratos da API.
