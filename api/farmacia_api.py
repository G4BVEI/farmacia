"""
API de Farmácia - User Facing (versão expandida)
-------------------------------------------------
Arquivo único com FastAPI + persistência em JSON.

Endpoints disponíveis:

  MEDICAMENTOS (CRUD + filtros)
  -----------------------------
  GET    /medicamentos                    → Lista com filtros e paginação
  GET    /medicamentos/{id}               → Detalhes de um medicamento
  POST   /medicamentos                    → Cadastra novo
  PUT    /medicamentos/{id}               → Atualiza
  DELETE /medicamentos/{id}               → Remove

  BUSCA E FILTROS
  ---------------
  GET    /medicamentos/buscar             → Busca por texto
  GET    /medicamentos/categoria/{nome}  → Filtra por categoria
  GET    /medicamentos/estoque-baixo      → Medicamentos com estoque baixo

  ESTOQUE
  -------
  PATCH  /medicamentos/{id}/estoque       → Ajusta estoque (entrada/saída)

  VENDAS (novo)
  -------------
  GET    /vendas                          → Lista vendas (mais recentes primeiro)
  GET    /vendas/{id}                     → Detalhes
  POST   /vendas                          → Cria venda (atômica: valida + baixa + grava)
  POST   /vendas/{id}/cancelar            → Cancela e devolve ao estoque

  CATEGORIAS
  ----------
  GET    /categorias                      → Lista todas as categorias + quantidade

  ESTATÍSTICAS
  ------------
  GET    /estatisticas                    → Resumo geral da farmácia

  SISTEMA
  -------
  GET    /                                → Health check

Para rodar:
  pip install fastapi uvicorn
  uvicorn farmacia_api:app --reload
"""

import json
from datetime import datetime
from math import ceil
from pathlib import Path
from typing import List, Optional

from fastapi import FastAPI, HTTPException, Query, status
from pydantic import BaseModel, Field

# ---------------------------------------------------------------------------
# Configuração
# ---------------------------------------------------------------------------

JSON_FILE = Path(__file__).parent / "medicamentos.json"
VENDAS_FILE = Path(__file__).parent / "vendas.json"
ESTOQUE_BAIXO_LIMITE = 30  # quantidade considerada "estoque baixo"

app = FastAPI(
    title="API de Farmácia",
    description="API user-facing completa para consulta e gerenciamento de medicamentos",
    version="2.1.0",
)

# ---------------------------------------------------------------------------
# Modelos Pydantic
# ---------------------------------------------------------------------------


class MedicamentoBase(BaseModel):
    nome: str = Field(..., min_length=2, max_length=120, examples=["Dipirona 500mg"])
    principio_ativo: str = Field(
        ..., min_length=2, max_length=120, examples=["Metamizol sódico"]
    )
    laboratorio: str = Field(..., min_length=2, max_length=80, examples=["Medley"])
    preco: float = Field(..., gt=0, examples=[12.90])
    estoque: int = Field(..., ge=0, examples=[150])
    categoria: str = Field(..., min_length=2, max_length=50, examples=["Analgésico"])
    requer_receita: bool = Field(default=False, examples=[False])
    descricao: Optional[str] = Field(
        None, max_length=500, examples=["Indicada para dores e febre"]
    )


class MedicamentoCreate(MedicamentoBase):
    """Modelo usado no POST (criação)."""

    pass


class MedicamentoUpdate(BaseModel):
    """Modelo usado no PUT (atualização parcial ou total)."""

    nome: Optional[str] = Field(None, min_length=2, max_length=120)
    principio_ativo: Optional[str] = Field(None, min_length=2, max_length=120)
    laboratorio: Optional[str] = Field(None, min_length=2, max_length=80)
    preco: Optional[float] = Field(None, gt=0)
    estoque: Optional[int] = Field(None, ge=0)
    categoria: Optional[str] = Field(None, min_length=2, max_length=50)
    requer_receita: Optional[bool] = None
    descricao: Optional[str] = Field(None, max_length=500)


class Medicamento(MedicamentoBase):
    """Modelo de resposta (inclui o ID)."""

    id: int


class AjusteEstoque(BaseModel):
    """Modelo para ajustar estoque (entrada positiva / saída negativa)."""

    quantidade: int = Field(
        ..., description="Positivo = entrada | Negativo = saída", examples=[10, -5]
    )
    motivo: Optional[str] = Field(
        None, max_length=200, examples=["Compra de fornecedor", "Venda no balcão"]
    )


class PaginatedResponse(BaseModel):
    total: int
    pagina: int
    por_pagina: int
    total_paginas: int
    itens: List[Medicamento]


class CategoriaInfo(BaseModel):
    nome: str
    quantidade: int


class Estatisticas(BaseModel):
    total_medicamentos: int
    total_em_estoque: int
    valor_total_estoque: float
    medicamentos_com_receita: int
    medicamentos_sem_receita: int
    estoque_baixo: int
    categorias: List[CategoriaInfo]


# ---- Vendas ----


class ItemVendaCreate(BaseModel):
    medicamento_id: int
    quantidade: int = Field(..., gt=0)


class VendaCreate(BaseModel):
    itens: List[ItemVendaCreate] = Field(..., min_length=1)
    pagamento: str = Field(..., pattern="^(pix|dinheiro|debito|credito)$")
    desconto_pct: float = Field(0, ge=0, le=100)
    cliente: Optional[str] = Field(None, max_length=120)


class ItemVenda(BaseModel):
    medicamento_id: int
    nome: str
    quantidade: int
    preco_unitario: float
    subtotal: float


class Venda(BaseModel):
    id: int
    data: str
    itens: List[ItemVenda]
    subtotal: float
    desconto_pct: float
    desconto_valor: float
    total: float
    pagamento: str
    cliente: Optional[str] = None
    cancelada: bool = False


# ---------------------------------------------------------------------------
# Persistência em JSON - medicamentos
# ---------------------------------------------------------------------------


def _dados_iniciais() -> List[dict]:
    """Retorna uma lista com dados de exemplo."""
    return [
        {
            "id": 1,
            "nome": "Dipirona 500mg",
            "principio_ativo": "Metamizol sódico",
            "laboratorio": "Medley",
            "preco": 12.90,
            "estoque": 150,
            "categoria": "Analgésico",
            "requer_receita": False,
            "descricao": "Indicada para dores e febre. Comprimidos.",
        },
        {
            "id": 2,
            "nome": "Amoxicilina 500mg",
            "principio_ativo": "Amoxicilina",
            "laboratorio": "EMS",
            "preco": 28.50,
            "estoque": 80,
            "categoria": "Antibiótico",
            "requer_receita": True,
            "descricao": "Antibiótico de amplo espectro. Cápsulas.",
        },
        {
            "id": 3,
            "nome": "Losartana 50mg",
            "principio_ativo": "Losartana potássica",
            "laboratorio": "Eurofarma",
            "preco": 18.75,
            "estoque": 200,
            "categoria": "Anti-hipertensivo",
            "requer_receita": True,
            "descricao": "Controle da pressão arterial. Comprimidos.",
        },
        {
            "id": 4,
            "nome": "Paracetamol 750mg",
            "principio_ativo": "Paracetamol",
            "laboratorio": "Neo Química",
            "preco": 9.90,
            "estoque": 300,
            "categoria": "Analgésico",
            "requer_receita": False,
            "descricao": "Alívio de dores e redução de febre.",
        },
        {
            "id": 5,
            "nome": "Omeprazol 20mg",
            "principio_ativo": "Omeprazol",
            "laboratorio": "Medley",
            "preco": 22.40,
            "estoque": 120,
            "categoria": "Protetor Gástrico",
            "requer_receita": False,
            "descricao": "Tratamento de refluxo e úlceras. Cápsulas.",
        },
        {
            "id": 6,
            "nome": "Ibuprofeno 600mg",
            "principio_ativo": "Ibuprofeno",
            "laboratorio": "EMS",
            "preco": 15.30,
            "estoque": 25,
            "categoria": "Anti-inflamatório",
            "requer_receita": False,
            "descricao": "Alívio de dores e inflamações.",
        },
        {
            "id": 7,
            "nome": "Sinvastatina 20mg",
            "principio_ativo": "Sinvastatina",
            "laboratorio": "Eurofarma",
            "preco": 14.80,
            "estoque": 110,
            "categoria": "Hipolipemiante",
            "requer_receita": True,
            "descricao": "Controle do colesterol. Comprimidos.",
        },
        {
            "id": 8,
            "nome": "Vitamina C 1g",
            "principio_ativo": "Ácido ascórbico",
            "laboratorio": "Cimed",
            "preco": 19.90,
            "estoque": 180,
            "categoria": "Suplemento",
            "requer_receita": False,
            "descricao": "Suplemento vitamínico efervescente.",
        },
        {
            "id": 9,
            "nome": "Dorflex",
            "principio_ativo": "Dipirona + Orfenadrina + Cafeína",
            "laboratorio": "Sanofi",
            "preco": 24.90,
            "estoque": 15,
            "categoria": "Analgésico",
            "requer_receita": False,
            "descricao": "Alívio de dores musculares e tensionais.",
        },
        {
            "id": 10,
            "nome": "Rivotril 2mg",
            "principio_ativo": "Clonazepam",
            "laboratorio": "Roche",
            "preco": 32.00,
            "estoque": 40,
            "categoria": "Ansiolítico",
            "requer_receita": True,
            "descricao": "Controle de ansiedade e convulsões. Comprimidos.",
        },
    ]


def carregar_dados() -> List[dict]:
    if not JSON_FILE.exists():
        dados = _dados_iniciais()
        salvar_dados(dados)
        return dados
    try:
        with open(JSON_FILE, "r", encoding="utf-8") as f:
            return json.load(f)
    except (json.JSONDecodeError, OSError):
        dados = _dados_iniciais()
        salvar_dados(dados)
        return dados


def salvar_dados(dados: List[dict]) -> None:
    with open(JSON_FILE, "w", encoding="utf-8") as f:
        json.dump(dados, f, ensure_ascii=False, indent=2)


def gerar_proximo_id(dados: List[dict]) -> int:
    if not dados:
        return 1
    return max(item["id"] for item in dados) + 1


def buscar_por_id(dados: List[dict], medicamento_id: int) -> Optional[dict]:
    for item in dados:
        if item["id"] == medicamento_id:
            return item
    return None


# ---------------------------------------------------------------------------
# Persistência em JSON - vendas
# ---------------------------------------------------------------------------


def carregar_vendas() -> List[dict]:
    if not VENDAS_FILE.exists():
        return []
    try:
        with open(VENDAS_FILE, "r", encoding="utf-8") as f:
            return json.load(f)
    except (json.JSONDecodeError, OSError):
        return []


def salvar_vendas(vendas: List[dict]) -> None:
    with open(VENDAS_FILE, "w", encoding="utf-8") as f:
        json.dump(vendas, f, ensure_ascii=False, indent=2)


def gerar_proximo_id_venda(vendas: List[dict]) -> int:
    if not vendas:
        return 1
    return max(v["id"] for v in vendas) + 1


# ---------------------------------------------------------------------------
# Endpoints - SISTEMA
# ---------------------------------------------------------------------------


@app.get("/", tags=["Sistema"])
def root():
    return {
        "mensagem": "API de Farmácia está online!",
        "versao": "2.1.0",
        "documentacao": "/docs",
        "redoc": "/redoc",
    }


# ---------------------------------------------------------------------------
# Endpoints - MEDICAMENTOS (CRUD)
# ---------------------------------------------------------------------------


@app.get(
    "/medicamentos",
    response_model=PaginatedResponse,
    summary="Listar medicamentos (com filtros e paginação)",
    tags=["Medicamentos"],
)
def listar_medicamentos(
    pagina: int = Query(1, ge=1, description="Número da página"),
    por_pagina: int = Query(10, ge=1, le=50, description="Itens por página"),
    categoria: Optional[str] = Query(None, description="Filtrar por categoria"),
    requer_receita: Optional[bool] = Query(
        None, description="Filtrar por necessidade de receita"
    ),
    laboratorio: Optional[str] = Query(None, description="Filtrar por laboratório"),
    preco_min: Optional[float] = Query(None, ge=0, description="Preço mínimo"),
    preco_max: Optional[float] = Query(None, ge=0, description="Preço máximo"),
):
    dados = carregar_dados()

    if categoria:
        dados = [m for m in dados if m["categoria"].lower() == categoria.lower()]
    if requer_receita is not None:
        dados = [m for m in dados if m["requer_receita"] == requer_receita]
    if laboratorio:
        dados = [m for m in dados if laboratorio.lower() in m["laboratorio"].lower()]
    if preco_min is not None:
        dados = [m for m in dados if m["preco"] >= preco_min]
    if preco_max is not None:
        dados = [m for m in dados if m["preco"] <= preco_max]

    total = len(dados)
    total_paginas = ceil(total / por_pagina) if total > 0 else 0
    inicio = (pagina - 1) * por_pagina
    fim = inicio + por_pagina
    itens = dados[inicio:fim]

    return {
        "total": total,
        "pagina": pagina,
        "por_pagina": por_pagina,
        "total_paginas": total_paginas,
        "itens": itens,
    }


@app.get(
    "/medicamentos/{medicamento_id}",
    response_model=Medicamento,
    summary="Buscar medicamento por ID",
    tags=["Medicamentos"],
)
def obter_medicamento(medicamento_id: int):
    dados = carregar_dados()
    medicamento = buscar_por_id(dados, medicamento_id)
    if not medicamento:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Medicamento com ID {medicamento_id} não encontrado.",
        )
    return medicamento


@app.post(
    "/medicamentos",
    response_model=Medicamento,
    status_code=status.HTTP_201_CREATED,
    summary="Cadastrar novo medicamento",
    tags=["Medicamentos"],
)
def criar_medicamento(payload: MedicamentoCreate):
    dados = carregar_dados()
    novo = payload.model_dump()
    novo["id"] = gerar_proximo_id(dados)
    dados.append(novo)
    salvar_dados(dados)
    return novo


@app.put(
    "/medicamentos/{medicamento_id}",
    response_model=Medicamento,
    summary="Atualizar medicamento",
    tags=["Medicamentos"],
)
def atualizar_medicamento(medicamento_id: int, payload: MedicamentoUpdate):
    dados = carregar_dados()
    medicamento = buscar_por_id(dados, medicamento_id)
    if not medicamento:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Medicamento com ID {medicamento_id} não encontrado.",
        )
    atualizacoes = payload.model_dump(exclude_unset=True)
    medicamento.update(atualizacoes)
    salvar_dados(dados)
    return medicamento


@app.delete(
    "/medicamentos/{medicamento_id}",
    status_code=status.HTTP_204_NO_CONTENT,
    summary="Remover medicamento",
    tags=["Medicamentos"],
)
def remover_medicamento(medicamento_id: int):
    dados = carregar_dados()
    medicamento = buscar_por_id(dados, medicamento_id)
    if not medicamento:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Medicamento com ID {medicamento_id} não encontrado.",
        )
    dados = [item for item in dados if item["id"] != medicamento_id]
    salvar_dados(dados)
    return None


# ---------------------------------------------------------------------------
# Endpoints - BUSCA E FILTROS
# ---------------------------------------------------------------------------


@app.get(
    "/medicamentos/buscar",
    response_model=List[Medicamento],
    summary="Buscar medicamentos por texto",
    tags=["Busca e Filtros"],
)
def buscar_medicamentos(
    q: str = Query(..., min_length=1, description="Termo de busca"),
):
    dados = carregar_dados()
    termo = q.lower().strip()
    return [
        m
        for m in dados
        if termo in m["nome"].lower()
        or termo in m["principio_ativo"].lower()
        or termo in m["laboratorio"].lower()
    ]


@app.get(
    "/medicamentos/categoria/{categoria}",
    response_model=List[Medicamento],
    summary="Listar medicamentos por categoria",
    tags=["Busca e Filtros"],
)
def medicamentos_por_categoria(categoria: str):
    dados = carregar_dados()
    resultados = [m for m in dados if m["categoria"].lower() == categoria.lower()]
    if not resultados:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Nenhum medicamento encontrado na categoria '{categoria}'.",
        )
    return resultados


@app.get(
    "/medicamentos/estoque-baixo",
    response_model=List[Medicamento],
    summary="Medicamentos com estoque baixo",
    tags=["Busca e Filtros"],
)
def estoque_baixo(
    limite: int = Query(
        ESTOQUE_BAIXO_LIMITE, ge=1, description="Quantidade máxima considerada 'baixa'"
    ),
):
    dados = carregar_dados()
    return [m for m in dados if m["estoque"] <= limite]


# ---------------------------------------------------------------------------
# Endpoints - ESTOQUE
# ---------------------------------------------------------------------------


@app.patch(
    "/medicamentos/{medicamento_id}/estoque",
    response_model=Medicamento,
    summary="Ajustar estoque (entrada ou saída)",
    tags=["Estoque"],
)
def ajustar_estoque(medicamento_id: int, payload: AjusteEstoque):
    dados = carregar_dados()
    medicamento = buscar_por_id(dados, medicamento_id)
    if not medicamento:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Medicamento com ID {medicamento_id} não encontrado.",
        )
    novo_estoque = medicamento["estoque"] + payload.quantidade
    if novo_estoque < 0:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=(
                f"Estoque insuficiente. Disponível: {medicamento['estoque']}, "
                f"tentativa de saída: {abs(payload.quantidade)}."
            ),
        )
    medicamento["estoque"] = novo_estoque
    salvar_dados(dados)
    return medicamento


# ---------------------------------------------------------------------------
# Endpoints - VENDAS
# ---------------------------------------------------------------------------


@app.post(
    "/vendas",
    response_model=Venda,
    status_code=status.HTTP_201_CREATED,
    summary="Criar venda (atômica)",
    tags=["Vendas"],
)
def criar_venda(payload: VendaCreate):
    """
    Fluxo atômico:
      1) valida estoque de TODOS os itens
      2) calcula totais
      3) baixa estoque
      4) grava a venda
    Se qualquer passo falhar, nada é alterado.
    """
    medicamentos = carregar_dados()

    # 1) Validação
    for item in payload.itens:
        med = buscar_por_id(medicamentos, item.medicamento_id)
        if not med:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail=f"Medicamento {item.medicamento_id} não encontrado.",
            )
        if med["estoque"] < item.quantidade:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=(
                    f"Estoque insuficiente para {med['nome']}. "
                    f"Disponível: {med['estoque']}, pedido: {item.quantidade}."
                ),
            )

    # 2) Monta itens e totais
    itens: List[dict] = []
    subtotal = 0.0
    for item in payload.itens:
        med = buscar_por_id(medicamentos, item.medicamento_id)
        sub = round(med["preco"] * item.quantidade, 2)
        subtotal += sub
        itens.append(
            {
                "medicamento_id": med["id"],
                "nome": med["nome"],
                "quantidade": item.quantidade,
                "preco_unitario": med["preco"],
                "subtotal": sub,
            }
        )
    subtotal = round(subtotal, 2)
    desc_valor = round(subtotal * payload.desconto_pct / 100, 2)
    total = round(subtotal - desc_valor, 2)

    # 3) Baixa estoque
    for item in payload.itens:
        buscar_por_id(medicamentos, item.medicamento_id)["estoque"] -= item.quantidade
    salvar_dados(medicamentos)

    # 4) Grava venda
    vendas = carregar_vendas()
    nova = {
        "id": gerar_proximo_id_venda(vendas),
        "data": datetime.now().isoformat(),
        "itens": itens,
        "subtotal": subtotal,
        "desconto_pct": payload.desconto_pct,
        "desconto_valor": desc_valor,
        "total": total,
        "pagamento": payload.pagamento,
        "cliente": payload.cliente,
        "cancelada": False,
    }
    vendas.append(nova)
    salvar_vendas(vendas)
    return nova


@app.get(
    "/vendas",
    response_model=List[Venda],
    summary="Listar vendas (mais recentes primeiro)",
    tags=["Vendas"],
)
def listar_vendas():
    return list(reversed(carregar_vendas()))


@app.get(
    "/vendas/{venda_id}",
    response_model=Venda,
    summary="Detalhes de uma venda",
    tags=["Vendas"],
)
def obter_venda(venda_id: int):
    for v in carregar_vendas():
        if v["id"] == venda_id:
            return v
    raise HTTPException(
        status_code=status.HTTP_404_NOT_FOUND,
        detail=f"Venda {venda_id} não encontrada.",
    )


@app.post(
    "/vendas/{venda_id}/cancelar",
    response_model=Venda,
    summary="Cancelar venda e devolver ao estoque",
    tags=["Vendas"],
)
def cancelar_venda(venda_id: int):
    vendas = carregar_vendas()
    venda = next((v for v in vendas if v["id"] == venda_id), None)
    if not venda:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Venda {venda_id} não encontrada.",
        )
    if venda["cancelada"]:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Venda já cancelada.",
        )

    medicamentos = carregar_dados()
    for item in venda["itens"]:
        med = buscar_por_id(medicamentos, item["medicamento_id"])
        if med:  # medicamento pode ter sido removido do catálogo
            med["estoque"] += item["quantidade"]
    salvar_dados(medicamentos)

    venda["cancelada"] = True
    salvar_vendas(vendas)
    return venda


# ---------------------------------------------------------------------------
# Endpoints - CATEGORIAS
# ---------------------------------------------------------------------------


@app.get(
    "/categorias",
    response_model=List[CategoriaInfo],
    summary="Listar categorias",
    tags=["Categorias"],
)
def listar_categorias():
    dados = carregar_dados()
    contagem: dict[str, int] = {}
    for m in dados:
        cat = m["categoria"]
        contagem[cat] = contagem.get(cat, 0) + 1
    return [{"nome": nome, "quantidade": qtd} for nome, qtd in sorted(contagem.items())]


# ---------------------------------------------------------------------------
# Endpoints - ESTATÍSTICAS
# ---------------------------------------------------------------------------


@app.get(
    "/estatisticas",
    response_model=Estatisticas,
    summary="Estatísticas gerais da farmácia",
    tags=["Estatísticas"],
)
def obter_estatisticas():
    dados = carregar_dados()
    total_medicamentos = len(dados)
    total_em_estoque = sum(m["estoque"] for m in dados)
    valor_total = sum(m["preco"] * m["estoque"] for m in dados)
    com_receita = sum(1 for m in dados if m["requer_receita"])
    sem_receita = total_medicamentos - com_receita
    baixo = sum(1 for m in dados if m["estoque"] <= ESTOQUE_BAIXO_LIMITE)

    contagem: dict[str, int] = {}
    for m in dados:
        cat = m["categoria"]
        contagem[cat] = contagem.get(cat, 0) + 1
    categorias = [
        {"nome": nome, "quantidade": qtd} for nome, qtd in sorted(contagem.items())
    ]

    return {
        "total_medicamentos": total_medicamentos,
        "total_em_estoque": total_em_estoque,
        "valor_total_estoque": round(valor_total, 2),
        "medicamentos_com_receita": com_receita,
        "medicamentos_sem_receita": sem_receita,
        "estoque_baixo": baixo,
        "categorias": categorias,
    }


# ---------------------------------------------------------------------------
# Execução direta
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    import uvicorn

    uvicorn.run("farmacia_api:app", host="0.0.0.0", port=8000, reload=True)
