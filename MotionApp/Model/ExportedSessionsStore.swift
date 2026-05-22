//
//  ExportedSessionsStore.swift
//  MotionApp
//
//  Created on 2026-05-14 — Etapa D.
//
//  Persiste em UserDefaults o conjunto de sessionIds cujo CSV já foi exportado
//  com sucesso. Side-state mínimo para a estratégia "mark exported + manual purge":
//  o Core Data continua segurando os dados raw até o usuário explicitamente
//  pedir cleanup; o que esse store responde é "esta sessão precisa de export
//  novamente?" (i.e., é órfã?).
//
//  Por quê UserDefaults e não um arquivo / Core Data próprio:
//  - É só um Set<UUID> pequeno (mesmo com 100 sessões = 3.6KB de strings)
//  - Sobrevive a app kill / reinstalação dentro do mesmo bundle
//  - API trivial, zero código boilerplate
//  - Sem dependência circular com o Core Data store
//

import Foundation

final class ExportedSessionsStore {

    private let key = "MoveCollector.exportedSessionIds.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Retorna o conjunto atual de UUIDs marcados como exportados.
    /// Usa Set<UUID> em vez de Set<String> na API pública para evitar
    /// parsing repetido pelos chamadores.
    func allExported() -> Set<UUID> {
        let stored = defaults.array(forKey: key) as? [String] ?? []
        return Set(stored.compactMap(UUID.init(uuidString:)))
    }

    /// True se a sessão já tem CSV exportado registrado.
    func isExported(_ id: UUID) -> Bool {
        let stored = defaults.array(forKey: key) as? [String] ?? []
        return stored.contains(id.uuidString)
    }

    /// Marca uma sessão como exportada. Idempotente.
    /// Por quê salvar a cada chamada (em vez de buffer + flush):
    /// - UserDefaults faz batching interno (escreve em ~ms async)
    /// - Garantir durabilidade imediata é mais valioso do que micro-otimizar:
    ///   se o app crashar entre export bem-sucedido e marcar exportada,
    ///   a próxima execução trata a sessão como órfã e re-exporta.
    ///   Não é fim do mundo (CSV duplicado), mas perder a marca é pior.
    func markExported(_ id: UUID) {
        var stored = Set(defaults.array(forKey: key) as? [String] ?? [])
        stored.insert(id.uuidString)
        defaults.set(Array(stored), forKey: key)
    }

    /// Remove uma sessão da lista de exportadas. Usado depois de deletar
    /// os dados da sessão no Core Data — sem isso, o registro de
    /// "exportada" persistiria pra sempre sem dado correspondente.
    func unmark(_ id: UUID) {
        var stored = Set(defaults.array(forKey: key) as? [String] ?? [])
        stored.remove(id.uuidString)
        defaults.set(Array(stored), forKey: key)
    }
}
