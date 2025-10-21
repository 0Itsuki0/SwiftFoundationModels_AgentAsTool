//
//  AgentAsTool.swift
//  FoundationModelsMultiAgent
//
//  Created by Itsuki on 2025/10/20.
//

import SwiftUI
import FoundationModels

// The maximum number of turns to run the agent for.
// A turn is defined as one AI invocation (including any tool calls that might occur).
private actor MaxTurnMonitor {
    let maxTurn: Int
    init(maxTurn: Int) {
        self.maxTurn = maxTurn
    }
    
    enum Error: Swift.Error, LocalizedError {
        case maxTurnExceed
        
        public var errorDescription: String? {
            switch self {
            case .maxTurnExceed:
                return "Max Turn for answering user's prompt is exceeded."
            }
        }
        
        public var recoverySuggestion: String? {
            switch self {
            case .maxTurnExceed:
                return "Please provide a response based on the information you have."
            }
        }
    }
    
    var currentTurn = 0
    
    func checkAndIncrement() throws {
        currentTurn = currentTurn + 1
        if self.currentTurn > maxTurn {
            throw Error.maxTurnExceed
        }
    }
}


private struct AgentTool: Tool {
    let name: String
    let description: String
    var agent: Agent

    @Generable
    struct Arguments {
        @Guide(description: "A prompt for the agent to respond to.")
        let prompt: String
    }

    
    func call(arguments: Arguments) async throws -> String {
        print("Running Agent tool: \(name)")
        // not throwing so that the main agent can still provide a response based on the information it has.
        do {
            return try await self.agent._run(prompt: arguments.prompt)
        } catch(let error) {
            
            if let recoverySuggestion = (error as NSError).localizedRecoverySuggestion {
                return "Error: \(error.localizedDescription) \n\(recoverySuggestion)"
            } else {
                return "Error: \(error.localizedDescription)."
            }
        }
    }
}

private
extension Array where Element == any Tool {
    var agentTools: [AgentTool] {
        return self.filter({$0 is AgentTool}).map({$0 as! AgentTool})
    }
}



@Observable
private class Agent {
    
    var session: LanguageModelSession
    
    let name: String
    
    private let promptTransformer: ((String) -> String)?

    @ObservationIgnored
    var maxTurnMonitor: MaxTurnMonitor?
    
    private let agentAsTools: [Agent]
    
    init(name: String, instruction: String, tools: [any Tool], promptTransformer: ((String) -> String)? = nil) {
        self.name = name
        self.session = .init(
            model: SystemLanguageModel.default,
            tools: tools,
            instructions: instruction
        )
        self.promptTransformer = promptTransformer
        self.agentAsTools = tools.agentTools.map(\.agent)
    }
    
    
    @discardableResult
    func run(prompt: String, maxTurn: Int? = nil) async throws -> String {
        if let maxTurn {
            self.maxTurnMonitor = MaxTurnMonitor(maxTurn: maxTurn)
        } else {
            self.maxTurnMonitor = nil
        }
        self.agentAsTools.forEach({
            $0.maxTurnMonitor = self.maxTurnMonitor
        })
        
        return try await _run(prompt: prompt)
    }
    

    func _run(prompt: String) async throws -> String {
        try await maxTurnMonitor?.checkAndIncrement()

        let prompt = self.promptTransformer?(prompt) ?? prompt
        let response = try await session.respond(to: prompt)

        return response.content        
    }
    
        
    func asTool(description: String, name: String? = nil) -> AgentTool {
        return AgentTool(name: name ?? self.name, description: description, agent: self)
    }
}




extension AgentAsToolDemo {
    init() {
        
        let englishAssistant = Agent(
            name: "EnglishAssistant",
            instruction: """
        You are English master, an advanced English education assistant. Your capabilities include:

        1. Writing Support:
           - Grammar and syntax improvement
           - Vocabulary enhancement
           - Style and tone refinement
           - Structure and organization guidance

        2. Analysis Tools:
           - Text summarization
           - Literary analysis
           - Content evaluation
           - Citation assistance

        3. Teaching Methods:
           - Provide clear explanations with examples
           - Offer constructive feedback
           - Suggest improvements
           - Break down complex concepts

        Focus on being clear, encouraging, and educational in all interactions. Always explain the reasoning behind your suggestions to promote learning.
        """,
            tools: [],
            promptTransformer: {
                return "Analyze and respond to this English language or literature question, providing clear explanations with examples where appropriate: \($0)"
            }
        )

        let mathAssistant = Agent(
            name: "MathAssistant",
            instruction: """
        You are math wizard, a specialized mathematics education assistant. Your capabilities include:

        1. Mathematical Operations:
           - Arithmetic calculations
           - Algebraic problem-solving
           - Geometric analysis
           - Statistical computations

        2. Teaching Tools:
           - Step-by-step problem solving
           - Visual explanation creation
           - Formula application guidance
           - Concept breakdown

        3. Educational Approach:
           - Show detailed work
           - Explain mathematical reasoning
           - Provide alternative solutions
           - Link concepts to real-world applications

        Focus on clarity and systematic problem-solving while ensuring students understand the underlying concepts.
        """,
            tools: [],
            promptTransformer: {
                return "Please solve the following mathematical problem, showing all steps and explaining concepts clearly: \($0)"
            }
        )
        
        self.teacher = Agent(name: "Teacher", instruction: """
        You are TeachAssist, a sophisticated educational orchestrator designed to coordinate educational support across multiple subjects. Your role is to:

        1. Analyze incoming student queries and determine the most appropriate specialized agent to handle them:
           - MathAssistant: For mathematical calculations, problems, and concepts
           - EnglishAssistant: For writing, grammar, literature, and composition

        2. Key Responsibilities:
           - Accurately classify student queries by subject area
           - Route requests to the appropriate specialized agent
           - Maintain context and coordinate multi-step problems
           - Ensure cohesive responses when multiple agents are needed

        3. Decision Protocol:
           - If query involves calculations/numbers → Math Agent
           - If query involves writing/literature/grammar → English Agent
           - For complex queries, coordinate multiple agents as needed

        Always confirm your understanding before routing to ensure accurate assistance.
        """, tools: [
            englishAssistant.asTool(description: "An assistant For helping students with english writing, grammar, literature, and composition"),
            mathAssistant.asTool(description: "An assistant For helping students with mathematical calculations, problems, and concepts")
        ])
    }
}


struct AgentAsToolDemo: View {
    
    @State private var teacher: Agent
    @State private var error: Error?
    @State private var entry: String = """
2 questions:
1. A fair six-sided die is rolled. If the outcome is an odd number, what is the probability that the number is prime?
2. Analyze how Shakespeare uses the imagery of light and darkness to explore the theme of good versus evil in Macbeth
"""
    @State private var scrollPosition: ScrollPosition = .init()
    
    @State private var entryHeight: CGFloat = 24

    var body: some View {
        ScrollViewReader { proxy in
            List {
                VStack(alignment: .leading, spacing: 4) {
                    Text("FoundationModel + AgentAsTool + Turn Limits")
                        .font(.title2)
                        .fontWeight(.bold)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .foregroundStyle(.white)
                    
                    Spacer()
                        .frame(height: 4)

                    Group {
                        Text("Main orchestrator Agent: Teacher")
                        Text("Agent as Tools: Math Assistant,English Assistant")
                    }
                    .foregroundStyle(.gray)
                    .font(.subheadline)
                    
                    Spacer()
                        .frame(height: 4)
                    
                    Text("Max Turn: 2. (A turn is defined as one AI invocation (including any tool calls that might occur)")
                        .foregroundStyle(.gray)
                        .font(.subheadline)

                }
                .padding(.bottom, 16)

                
                if let error = error {
                    Text(String("\(error)"))
                        .foregroundStyle(.red)
                        .listRowSeparator(.hidden)
                    
                }
                
                ForEach(teacher.session.transcript) { transcript in

                    Group {
                        switch transcript {
                        case .response(let response):
                            Text(response.description)
                                .listRowBackground(Color.clear)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.all, 16)
                                .background(RoundedRectangle(cornerRadius: 24).fill(.green))
                                .padding(.trailing, 64)

                            
                        case .prompt(let prompt):
                            Text(prompt.description)
                                .listRowBackground(Color.clear)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.all, 16)
                                .background(RoundedRectangle(cornerRadius: 24).fill(.yellow))
                                .padding(.leading, 64)

                            
                        case .toolCalls(let toolCalls):
                            VStack(alignment: .leading, content: {
                                Text("Tool Calls")
                                ForEach(toolCalls) { call in
                                    Text(String("- [\(call.toolName)]: \(call.arguments.jsonString)"))
                                }
                            })
                            .listRowBackground(Color.clear)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .font(.subheadline)
                            .foregroundStyle(.gray)
                            
                        case .toolOutput(let toolOutput):
                            Text(toolOutput.description)
                                .listRowBackground(Color.clear)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .font(.subheadline)
                                .foregroundStyle(.gray)


                        default :
                            EmptyView()
                        }
                    }
                    .multilineTextAlignment(.leading)
                    .listRowInsets(.all, 0)
                    .padding(.vertical, 16)
                    .listRowSeparator(.hidden)
                    
                }
            }
            .listRowInsets(.vertical, 8)
            .foregroundStyle(.black)
            .font(.headline)
            .scrollTargetLayout()
            .frame(maxWidth: .infinity)
            .scrollPosition($scrollPosition, anchor: .bottom)
            .defaultScrollAnchor(.bottom, for: .alignment)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .onChange(of: self.teacher.session.transcript, initial: true, {
                if let last = self.teacher.session.transcript.last {
                    proxy.scrollTo(last.id)
                }
            })
        }
        .frame(minWidth: 480, minHeight: 400)
        .padding(.bottom, self.entryHeight)
        .overlay(alignment: .bottom, content: {
            HStack(spacing: 12) {
                TextEditor(text: $entry)
                    .onSubmit({
                        self.sendPrompt()
                    })
                    .textEditorStyle(.plain)
                    .font(.system(size: 16))
                    .foregroundStyle(.background.opacity(0.8))
                    .padding(.all, 4)
                    .background(RoundedRectangle(cornerRadius: 4)
                        .stroke(.gray, style: .init(lineWidth: 1))
                        .fill(.white)
                    )
                    .frame(maxHeight: 120)
                    .fixedSize(horizontal: false, vertical: true)
                
                Button(action: {
                    self.sendPrompt()
                }, label: {
                    Image(systemName: "paperplane.fill")
                })
                .buttonStyle(.glass)
                .foregroundStyle(.blue)
                .disabled(self.teacher.session.isResponding)
                
            }
            .padding(.vertical, 16)
            .padding(.horizontal, 24)
            .background(.yellow.opacity(0.2))
            .background(.white)
            .onGeometryChange(for: CGFloat.self, of: {
                $0.size.height
            }, action: { old, new in
                self.entryHeight = new
            })
            
        })
    }
        
    private func sendPrompt() {
        let entry = self.entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !entry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        guard !self.teacher.session.isResponding else {
            return
        }
        
        self.entry = ""

        Task {
            do {
                let result = try await self.teacher.run(prompt: entry, maxTurn: 2)
                print(result)
            } catch(let error) {
                self.error = error
            }
        }

    }
}


#Preview {
    AgentAsToolDemo()
}
