# App de Farmácia

Aplicativo simples para gerenciamento de uma farmácia, com frontend em Flutter e API desenvolvida em Python usando FastAPI.

## Tecnologias

- **Flutter** — aplicativo mobile
- **Python / FastAPI** — API REST
- **Uvicorn** — servidor da API
- **ADB** — comunicação USB com o dispositivo Android

## Estrutura

```text
farmacia/
├── api/    # Backend e API
├── app/    # Aplicativo Flutter
└── dev.sh  # Script para iniciar o ambiente
```

## Como executar

É necessário ter Python, Flutter e ADB instalados, além de um dispositivo Android conectado via USB com a depuração USB ativada.

Na raiz do projeto, execute:

```bash
chmod +x dev.sh
./dev.sh
```

O script inicia a API, configura o redirecionamento de portas e executa o aplicativo Flutter.

## Redirecionamento de portas (ADB Reverse)

Como o aplicativo roda no celular e a API roda no computador, precisamos permitir que o dispositivo acesse o servidor local.

Para isso, utilizamos o `adb reverse`:

```bash
adb reverse tcp:8000 tcp:8000
```

Esse comando redireciona a porta `8000` do dispositivo Android para a porta `8000` do computador através da conexão USB.

Assim, o aplicativo pode acessar a API por:

```text
http://127.0.0.1:8000
```

Sem precisar descobrir o IP da máquina, configurar a rede local ou utilizar serviços externos como túneis.

Ao encerrar o script, o redirecionamento é removido automaticamente.

## API

A API fica disponível em:

```text
http://127.0.0.1:8000
```

A documentação interativa pode ser acessada em:

```text
http://127.0.0.1:8000/docs
```
