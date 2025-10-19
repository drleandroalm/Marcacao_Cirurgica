import Foundation
import SwiftUI
import Observation

@Observable
@MainActor
class SurgicalRequestForm {
    var fields: [TemplateField]
    var currentFieldIndex: Int = 0
    
    // Post-transcription decision fields
    var needsCTI: Bool?
    var patientPrecaution: Bool?
    var needsOPME: Bool = false
    var opmeSpecification: String = ""
    
    // New: Hemocomponents reservation decision
    var needsHemocomponents: Bool? = nil
    var hemocomponentsSpecification: String = ""
    
    // Flags to track what was mentioned during transcription
    var ctiMentionedInTranscription: Bool = false
    var precautionMentionedInTranscription: Bool = false
    
    // Evidence snippets keyed by fieldId
    var evidenceSnippets: [String: String] = [:]
    @ObservationIgnored var highlightSpans: [String: HighlightedSpan] = [:]
    
    // Tracks fields flagged for refinement or low confidence
    var lowConfidenceFieldIds: Set<String> = []
    
    init() {
        self.fields = [
            TemplateField(
                id: "patientName",
                label: "Nome do Paciente",
                placeholder: "[Name of the paciente]",
                fieldType: .text
            ),
            TemplateField(
                id: "patientAge",
                label: "Idade do Paciente",
                placeholder: "[Age in years of the patient]",
                fieldType: .age
            ),
            TemplateField(
                id: "patientPhone",
                label: "Telefone do Paciente",
                placeholder: "[Phone number of the patient]",
                fieldType: .phone
            ),
            TemplateField(
                id: "surgeonName",
                label: "Nome do Cirurgião",
                placeholder: "[Name of Surgeon]",
                fieldType: .text
            ),
            TemplateField(
                id: "surgeryDate",
                label: "Data da Cirurgia",
                placeholder: "[Date of the surgery in the format of day/month/year]",
                fieldType: .date
            ),
            TemplateField(
                id: "surgeryTime",
                label: "Horário da Cirurgia",
                placeholder: "[Time of the Surgery]",
                fieldType: .time
            ),
            TemplateField(
                id: "procedureName",
                label: "Nome do Procedimento",
                placeholder: "[Name of the procedure]",
                fieldType: .text
            ),
            TemplateField(
                id: "procedureDuration",
                label: "Duração Estimada",
                placeholder: "[estimated time of the procedure]",
                fieldType: .duration
            )
        ]
    }
    
    var currentField: TemplateField? {
        guard currentFieldIndex < fields.count else { return nil }
        return fields[currentFieldIndex]
    }
    
    func updateCurrentFieldValue(_ value: String) {
        guard currentFieldIndex < fields.count else { return }
        fields[currentFieldIndex].value = value
    }
    
    func moveToNextField() -> Bool {
        guard currentFieldIndex < fields.count - 1 else { return false }
        currentFieldIndex += 1
        return true
    }
    
    func moveToPreviousField() -> Bool {
        guard currentFieldIndex > 0 else { return false }
        currentFieldIndex -= 1
        return true
    }
    
    func moveToField(at index: Int) {
        guard index >= 0 && index < fields.count else { return }
        currentFieldIndex = index
    }
    
    var isComplete: Bool {
        return fields.allSatisfy { $0.isComplete }
    }
    
    var isValid: Bool {
        return fields.allSatisfy { $0.validate() }
    }
    
    var progressPercentage: Double {
        let completedCount = fields.filter { $0.isComplete }.count
        return Double(completedCount) / Double(fields.count)
    }
    
    func generateFilledTemplate() -> String {
        // Format time to military format if needed
        let formattedTime = fields[5].value.isEmpty ? fields[5].placeholder : MilitaryTimeFormatter.format(fields[5].value)
        
        // Determine checkbox markings based on boolean values
        let precautionNo = patientPrecaution == false ? "X" : " "
        let precautionYes = patientPrecaution == true ? "X" : " "
        
        let ctiNo = needsCTI == false ? "X" : " "
        let ctiYes = needsCTI == true ? "X" : " "
        
        let opmeNo = needsOPME ? " " : "X"
        let opmeYes = needsOPME ? "X" : " "
        
        // Build OPME specification line if needed
        let opmeSpecLine = needsOPME ? "\n        Especificar: \(opmeSpecification)" : ""
        
        let template = """
        SOLICITAÇÃO DE AGENDAMENTO CIRÚRGICO
        
        DADOS DO PACIENTE:
        Nome: \(fields[0].value.isEmpty ? fields[0].placeholder : fields[0].value)
        Idade: \(fields[1].value.isEmpty ? fields[1].placeholder : fields[1].formattedValue())
        Telefone: \(fields[2].value.isEmpty ? fields[2].placeholder : fields[2].formattedValue())
        Preceptor: \(fields[3].value.isEmpty ? fields[3].placeholder : fields[3].value)
        Paciente em precaução: (\(precautionNo)) Não (\(precautionYes))Sim
        Paciente com doença infecto contagiosa: (X) Não ( )Sim
        DADOS DA CIRURGIA:
        Data: \(fields[4].value.isEmpty ? fields[4].placeholder : fields[4].value)
        Preferência de horário: \(formattedTime)
        Procedimento: \(fields[6].value.isEmpty ? fields[6].placeholder : fields[6].value)
        Convênio: SUS
        Necessidade de CTI: (\(ctiNo)) Não (\(ctiYes))Sim
        Reserva de hemocomponentes: (\(needsHemocomponents == false ? "X" : " ")) Não (\(needsHemocomponents == true ? "X" : " ")) Sim:    Especificar: \(needsHemocomponents == true ? hemocomponentsSpecification : "")
        Necessidade de OPME: (\(opmeNo)) Não (\(opmeYes)) Sim\(opmeSpecLine)
        Fornecedor:
        Necessidade de equipamentos específicos: (X) Não ( )Sim
        Especificar:
        Tempo do procedimento: \(fields[7].value.isEmpty ? fields[7].placeholder : fields[7].formattedValue())
        """
        
        return template
    }
    
    func reset() {
        for i in 0..<fields.count {
            fields[i].value = ""
        }
        currentFieldIndex = 0
        
        // Reset post-transcription decision fields
        needsCTI = nil
        patientPrecaution = nil
        needsOPME = false
        opmeSpecification = ""
        needsHemocomponents = nil
        hemocomponentsSpecification = ""
        ctiMentionedInTranscription = false
        precautionMentionedInTranscription = false
        evidenceSnippets.removeAll()
        lowConfidenceFieldIds.removeAll()
        highlightSpans.removeAll()
    }
}
