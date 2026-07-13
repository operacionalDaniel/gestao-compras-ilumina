-- ============================================================================
-- MÓDULO: Gestão de Compras (PO.04) — Solicitação de Orçamento → Cotações →
--         Ordem de Compra, com geração de ID sequencial atômica.
--
-- Como aplicar:
--   1. Ajuste a seção "ADAPTAÇÃO MULTI-TENANT" abaixo para bater com as
--      tabelas de tenants/usuários que você já usa no Indica.AI.
--   2. Rode este arquivo no SQL Editor do seu projeto Supabase (ou via
--      `supabase db push` se estiver usando migrations do CLI).
--   3. Crie o bucket de storage indicado no final (anexos de e-mail/PDF).
-- ============================================================================

-- ----------------------------------------------------------------------------
-- ADAPTAÇÃO MULTI-TENANT
-- ----------------------------------------------------------------------------
-- Este é um projeto Supabase novo (não é o mesmo do Indica.AI de produção),
-- então criamos aqui do zero a estrutura mínima de tenant + permissões,
-- no mesmo formato usado nos outros painéis (`painel_permissoes`), para
-- manter compatibilidade caso você um dia una os dois projetos.

create table if not exists public.tenants (
  id uuid primary key default gen_random_uuid(),
  nome text not null,
  created_at timestamptz not null default now()
);

create table if not exists public.painel_permissoes (
  user_id uuid not null references auth.users(id) on delete cascade,
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  painel text not null,
  ativo boolean not null default true,
  primary key (user_id, tenant_id, painel)
);

alter table public.tenants enable row level security;
alter table public.painel_permissoes enable row level security;

-- Qualquer usuário autenticado pode ler tenants (é só o nome/id, não é dado sensível)
create policy "autenticados podem ler tenants" on public.tenants
  for select using (auth.role() = 'authenticated');

-- Cada usuário só enxerga as próprias linhas de permissão
create policy "usuario le suas proprias permissoes" on public.painel_permissoes
  for select using (user_id = auth.uid());

-- Insere o tenant "Ilumina Içara" com o UUID que você já está usando,
-- se ele ainda não existir (evita duplicar caso rode este script de novo).
insert into public.tenants (id, nome)
values ('652de80d-3d09-4db8-b32b-229394abc976', 'Ilumina Içara')
on conflict (id) do nothing;

create or replace function public.current_tenant_ids()
returns setof uuid
language sql
stable
security definer
set search_path = public
as $$
  select tenant_id
  from public.painel_permissoes
  where user_id = auth.uid()
    and ativo = true
    and painel = 'compras'
$$;

-- ----------------------------------------------------------------------------
-- 1. CONTADORES — geração de ID atômica, sem repetir e sem perder contagem
-- ----------------------------------------------------------------------------
create table if not exists public.contadores (
  tenant_id uuid not null,
  tipo text not null,          -- 'SO' | 'CT' | 'OC'
  ano int not null,
  ultimo_numero int not null default 0,
  primary key (tenant_id, tipo, ano)
);

-- Função central: sempre que precisar de um novo número, é ESTA função que
-- deve ser chamada — nunca gere o ID no front-end (contagem local pode
-- duplicar entre abas/usuários). O UPSERT com ON CONFLICT é atômico: mesmo
-- em concorrência, o Postgres serializa as chamadas e nunca entrega o
-- mesmo número duas vezes nem pula um número.
create or replace function public.gerar_proximo_id(p_tenant_id uuid, p_tipo text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ano int := extract(year from now())::int;
  v_numero int;
begin
  insert into public.contadores (tenant_id, tipo, ano, ultimo_numero)
  values (p_tenant_id, p_tipo, v_ano, 1)
  on conflict (tenant_id, tipo, ano)
  do update set ultimo_numero = contadores.ultimo_numero + 1
  returning ultimo_numero into v_numero;

  return p_tipo || '-' || v_ano || '-' || lpad(v_numero::text, 4, '0');
end;
$$;

-- ----------------------------------------------------------------------------
-- 2. FORNECEDORES
-- ----------------------------------------------------------------------------
create table if not exists public.fornecedores (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  nome text not null,
  cnpj text,
  contato text,
  email text,
  telefone text,
  ativo boolean not null default true,
  qualificado_rq0714 boolean not null default false, -- Check List Qualificação Amb./Adm.
  created_at timestamptz not null default now()
);

-- ----------------------------------------------------------------------------
-- 3. SOLICITAÇÃO DE ORÇAMENTO (RQ.04.03) + ITENS
-- ----------------------------------------------------------------------------
create table if not exists public.solicitacoes_orcamento (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  numero text unique,                 -- preenchido via gerar_proximo_id('SO')
  data_solicitacao date not null default current_date,
  solicitante text,
  centro_custo text,                  -- obra / setor
  regime_urgente boolean not null default false,
  status text not null default 'aberta', -- aberta | em_cotacao | concluida | cancelada
  observacoes text,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now()
);

create table if not exists public.solicitacao_itens (
  id uuid primary key default gen_random_uuid(),
  solicitacao_id uuid not null references public.solicitacoes_orcamento(id) on delete cascade,
  codigo text,
  item text not null,
  unidade text,
  quantidade numeric not null default 1,
  ordem int not null default 0
);

-- ----------------------------------------------------------------------------
-- 4. COTAÇÕES RECEBIDAS (RQ.04.04 digital) + ITENS COTADOS
-- ----------------------------------------------------------------------------
create table if not exists public.cotacoes (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  numero text unique,                 -- preenchido via gerar_proximo_id('CT')
  solicitacao_id uuid not null references public.solicitacoes_orcamento(id) on delete cascade,
  fornecedor_id uuid not null references public.fornecedores(id),
  data_recebimento date not null default current_date,
  origem_email text,                  -- assunto/remetente do e-mail recebido
  anexo_path text,                    -- caminho no storage bucket 'cotacoes-anexos'
  frete numeric default 0,
  forma_pagamento text,
  prazo_entrega text,
  validade date,
  valor_total numeric not null default 0,
  vencedora boolean not null default false,
  observacoes text,
  created_at timestamptz not null default now()
);

create table if not exists public.cotacao_itens (
  id uuid primary key default gen_random_uuid(),
  cotacao_id uuid not null references public.cotacoes(id) on delete cascade,
  solicitacao_item_id uuid not null references public.solicitacao_itens(id),
  valor_unitario numeric not null default 0,
  valor_total numeric not null default 0,
  disponivel boolean not null default true
);

-- ----------------------------------------------------------------------------
-- 5. ORDEM DE COMPRA (RQ.04.21)
-- ----------------------------------------------------------------------------
create table if not exists public.ordens_compra (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  numero text unique,                 -- preenchido via gerar_proximo_id('OC')
  solicitacao_id uuid not null references public.solicitacoes_orcamento(id),
  cotacao_id uuid not null references public.cotacoes(id),
  fornecedor_id uuid not null references public.fornecedores(id),
  data_emissao date not null default current_date,
  valor_total numeric not null default 0,
  autorizado_por text,
  forma_autorizacao text,             -- 'email' | 'whatsapp'
  status text not null default 'emitida', -- emitida | recebida_parcial | recebida | encerrada | cancelada
  observacoes text,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now()
);

-- ----------------------------------------------------------------------------
-- 6. ÍNDICES
-- ----------------------------------------------------------------------------
create index if not exists idx_solicitacoes_tenant on public.solicitacoes_orcamento(tenant_id);
create index if not exists idx_cotacoes_tenant on public.cotacoes(tenant_id);
create index if not exists idx_cotacoes_solicitacao on public.cotacoes(solicitacao_id);
create index if not exists idx_oc_tenant on public.ordens_compra(tenant_id);
create index if not exists idx_fornecedores_tenant on public.fornecedores(tenant_id);

-- ----------------------------------------------------------------------------
-- 7. RLS (Row Level Security) — isolamento por tenant, igual ao resto do Indica.AI
-- ----------------------------------------------------------------------------
alter table public.fornecedores enable row level security;
alter table public.solicitacoes_orcamento enable row level security;
alter table public.solicitacao_itens enable row level security;
alter table public.cotacoes enable row level security;
alter table public.cotacao_itens enable row level security;
alter table public.ordens_compra enable row level security;
alter table public.contadores enable row level security;

create policy tenant_isolation_fornecedores on public.fornecedores
  for all using (tenant_id in (select current_tenant_ids()))
  with check (tenant_id in (select current_tenant_ids()));

create policy tenant_isolation_solicitacoes on public.solicitacoes_orcamento
  for all using (tenant_id in (select current_tenant_ids()))
  with check (tenant_id in (select current_tenant_ids()));

create policy tenant_isolation_solicitacao_itens on public.solicitacao_itens
  for all using (
    solicitacao_id in (select id from public.solicitacoes_orcamento where tenant_id in (select current_tenant_ids()))
  );

create policy tenant_isolation_cotacoes on public.cotacoes
  for all using (tenant_id in (select current_tenant_ids()))
  with check (tenant_id in (select current_tenant_ids()));

create policy tenant_isolation_cotacao_itens on public.cotacao_itens
  for all using (
    cotacao_id in (select id from public.cotacoes where tenant_id in (select current_tenant_ids()))
  );

create policy tenant_isolation_oc on public.ordens_compra
  for all using (tenant_id in (select current_tenant_ids()))
  with check (tenant_id in (select current_tenant_ids()));

create policy tenant_isolation_contadores on public.contadores
  for all using (tenant_id in (select current_tenant_ids()))
  with check (tenant_id in (select current_tenant_ids()));

-- ----------------------------------------------------------------------------
-- 8. STORAGE — bucket para anexos de cotação (PDF/print do e-mail recebido)
-- ----------------------------------------------------------------------------
insert into storage.buckets (id, name, public)
values ('cotacoes-anexos', 'cotacoes-anexos', false)
on conflict (id) do nothing;

create policy "usuarios com acesso a compras podem ler anexos"
  on storage.objects for select
  using (
    bucket_id = 'cotacoes-anexos'
    and auth.uid() in (
      select user_id from public.painel_permissoes
      where ativo = true and painel = 'compras'
    )
  );

create policy "usuarios com acesso a compras podem enviar anexos"
  on storage.objects for insert
  with check (
    bucket_id = 'cotacoes-anexos'
    and auth.uid() in (
      select user_id from public.painel_permissoes
      where ativo = true and painel = 'compras'
    )
  );

-- ============================================================================
-- FIM
-- Próximo passo:
--   1. Crie seu usuário em Authentication → Users → Add user (marque
--      "Auto Confirm User"), e copie o UID gerado.
--   2. INSERT INTO painel_permissoes (user_id, tenant_id, painel, ativo)
--      VALUES ('<seu user_id>', '652de80d-3d09-4db8-b32b-229394abc976', 'compras', true);
--   3. Testar: select public.gerar_proximo_id('652de80d-3d09-4db8-b32b-229394abc976', 'SO');
--      Deve devolver algo como 'SO-2026-0001'.
-- ============================================================================
