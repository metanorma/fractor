# Fractor Architecture

This document provides architecture diagrams and descriptions of the Fractor framework's components.

## Overview

Fractor is a function-driven Ractors framework for Ruby that provides true parallelism using Ruby's Ractor feature with automatic work distribution across isolated workers.

## High-Level Architecture

```mermaid
graph TB
    subgraph "Application Layer"
        Work[Work<br/>Immutable Input]
        Worker[Worker<br/>Processing Logic]
        WorkResult[WorkResult<br/>Success/Error Output]
    end

    subgraph "Orchestration Layer"
        Supervisor[Supervisor<br/>Main Orchestrator]
        ContinuousServer[ContinuousServer<br/>Long-Running Mode]
        WorkflowExecutor[WorkflowExecutor<br/>Multi-Step Pipelines]
    end

    subgraph "Concurrency Layer"
        WorkQueue[WorkQueue<br/>Thread-Safe Queue]
        ResultAggregator[ResultAggregator<br/>Thread-Safe Results]
        CallbackRegistry[CallbackRegistry<br/>Event Callbacks]
        WrappedRactor[WrappedRactor<br/>Ractor Wrapper]
        WorkDistributionManager[WorkDistributionManager<br/>Idle Worker Tracking]
    end

    subgraph "Ractor Layer"
        Ractor1[Ractor 1]
        Ractor2[Ractor 2]
        Ractor3[Ractor 3]
    end

    Work --> Supervisor
    Worker --> WorkflowExecutor
    WorkResult --> ResultAggregator

    Supervisor --> WorkQueue
    Supervisor --> ResultAggregator
    Supervisor --> CallbackRegistry
    Supervisor --> WorkDistributionManager

    ContinuousServer --> Supervisor

    WorkflowExecutor --> Supervisor
    WorkflowExecutor --> WorkQueue

    WorkDistributionManager --> WrappedRactor
    WrappedRactor --> Ractor1
    WrappedRactor --> Ractor2
    WrappedRactor --> Ractor3

    Ractor1 --> Worker
    Ractor2 --> Worker
    Ractor3 --> Worker

    style Work fill:#e1f5e1
    style Worker fill:#e1f5e1
    style WorkResult fill:#e1f5e1
    style Supervisor fill:#e3f2fd
    style ContinuousServer fill:#e3f2fd
    style WorkflowExecutor fill:#e3f2fd
    style WrappedRactor fill:#fff3e0
    style Ractor1 fill:#fce4ec
    style Ractor2 fill:#fce4ec
    style Ractor3 fill:#fce4ec
```

## Component Relationships

```mermaid
graph LR
    subgraph "User Code"
        MyWork[MyWork < Work]
        MyWorker[MyWorker < Worker]
    end

    subgraph "Fractor Core"
        Supervisor[Supervisor]
        Queue[WorkQueue]
        Results[ResultAggregator]
    end

    subgraph "Worker Pool"
        W1[Worker Ractor 1]
        W2[Worker Ractor 2]
        W3[Worker Ractor 3]
    end

    MyWork --> Supervisor
    MyWorker --> Supervisor

    Supervisor --> Queue
    Queue --> W1
    Queue --> W2
    Queue --> W3

    W1 --> Results
    W2 --> Results
    W3 --> Results

    Results --> Supervisor
    Supervisor --> MyWork
```

## Pipeline Mode Execution Flow

```mermaid
sequenceDiagram
    participant User
    participant Supervisor
    participant WorkQueue
    participant Worker as Worker Ractor
    participant Results
    participant Callback as CallbackRegistry

    User->>Supervisor: new(worker_pools: [...])
    User->>Supervisor: add_work_items(items)
    Supervisor->>WorkQueue: enqueue items
    User->>Supervisor: run()

    loop Main Loop
        Supervisor->>WorkQueue: pop_batch()
        WorkQueue-->>Supervisor: work items

        Supervisor->>Worker: send work
        Worker->>Worker: process(work)
        Worker-->>Supervisor: WorkResult
        Supervisor->>Results: add(result)

        Supervisor->>Callback: process_work_callbacks()
        Callback-->>Supervisor: new_work (optional)
    end

    Supervisor-->>User: results
```

## Continuous Mode Execution Flow

```mermaid
sequenceDiagram
    participant User
    participant Server as ContinuousServer
    participant Supervisor
    participant Queue as WorkQueue
    participant Callbacks as CallbackRegistry

    User->>Server: new(worker_pools, work_queue)
    Server->>Supervisor: new(continuous_mode: true)
    Queue->>Supervisor: register_work_source()
    Server->>Server: run()

    loop Continuous Processing
        Supervisor->>Callbacks: process_work_callbacks()
        Callbacks-->>Supervisor: new work items
        Supervisor->>Queue: enqueue new work
        Note over Supervisor,Queue: Distribute to workers

        Server->>Server: on_result callback
        Server->>Server: on_error callback
    end

    User->>Server: stop() / Ctrl+C
    Server->>Supervisor: stop()
    Server-->>User: shutdown complete
```

## Workflow System Architecture

```mermaid
graph TB
    subgraph "Workflow Definition"
        DSL[Workflow DSL]
        Builder[Workflow Builder]
        Job[Job Definitions]
    end

    subgraph "Workflow Execution"
        Executor[WorkflowExecutor]
        Resolver[DependencyResolver<br/>Topological Sort]
        Logger[WorkflowExecutionLogger]
    end

    subgraph "Execution Components"
        JobExecutor[JobExecutor]
        Retry[RetryOrchestrator]
        Circuit[CircuitBreakerOrchestrator]
        Fallback[FallbackJobHandler]
        DLQ[DeadLetterQueue]
    end

    DSL --> Builder
    Builder --> Job
    Job --> Executor

    Executor --> Resolver
    Executor --> Logger
    Executor --> JobExecutor

    JobExecutor --> Retry
    JobExecutor --> Circuit
    JobExecutor --> Fallback
    JobExecutor --> DLQ
```

## Ruby Version-Specific Architecture

```mermaid
graph LR
    subgraph "Ruby 3.x"
        R3Handler[MainLoopHandler]
        R3Wrapped[WrappedRactor]
        R3Method[Ractor.yield / Ractor.receive]
    end

    subgraph "Ruby 4.0+"
        R4Handler[MainLoopHandler4]
        R4Wrapped[WrappedRactor4]
        R4Method[Ractor::Port / Ractor.select]
    end

    subgraph "Shared"
        Supervisor[Supervisor]
        Common[Common Components]
    end

    Supervisor --> R3Handler
    Supervisor --> R4Handler

    R3Handler --> R3Wrapped
    R3Wrapped --> R3Method

    R4Handler --> R4Wrapped
    R4Wrapped --> R4Method

    R3Handler --> Common
    R4Handler --> Common
```

## Component Responsibilities

### Application Layer

| Component | Responsibility |
|-----------|---------------|
| **Work** | Immutable data container with input data |
| **Worker** | Processing logic with `process(work)` method |
| **WorkResult** | Contains success/failure status, result value, or error |

### Orchestration Layer

| Component | Responsibility |
|-----------|---------------|
| **Supervisor** | Main orchestrator for pipeline mode, manages worker lifecycle |
| **ContinuousServer** | High-level wrapper for long-running services |
| **WorkflowExecutor** | Orchestrates multi-step workflow executions |

### Concurrency Layer

| Component | Responsibility |
|-----------|---------------|
| **WorkQueue** | Thread-safe queue for work items |
| **ResultAggregator** | Thread-safe result collection with event notifications |
| **CallbackRegistry** | Manages work source and error callbacks |
| **WrappedRactor** | Safe wrapper around Ruby Ractor with version-specific implementations |
| **WorkDistributionManager** | Tracks idle workers and distributes work efficiently |

### Ractor Layer

| Component | Responsibility |
|-----------|---------------|
| **Ractor 1, 2, 3...** | Isolated Ruby Ractors containing Worker instances |
| **Worker instances** | Each Ractor has its own Worker instance for processing |

## Data Flow

### Work Processing Flow

```mermaid
graph LR
    A[User creates Work] --> B[Supervisor.add_work_item]
    B --> C[WorkQueue]
    C --> D[WorkDistributionManager]
    D --> E[Idle Worker Ractor]
    E --> F[Worker.process]
    F --> G[WorkResult]
    G --> H[ResultAggregator]
    H --> I[User retrieves results]
```

### Error Handling Flow

```mermaid
graph LR
    A[Worker.process raises error] --> B[WorkResult with error]
    B --> C[ErrorReporter]
    C --> D[ErrorStatistics]
    C --> E[ErrorCallbacks]
    E --> F[User error handler]
    D --> G[ErrorReportGenerator]
    G --> H[Formatted error output]
```

## Key Design Principles

1. **Function-Driven**: Work is defined as input → processing → output
2. **Message Passing**: Ractors communicate via messages, no shared state
3. **Immutability**: Work objects are immutable, ensuring thread safety
4. **Isolation**: Each Worker runs in its own Ractor with isolated memory
5. **Scalability**: Automatically distribute work across available workers
6. **Fault Tolerance**: Errors are captured without crashing other workers
7. **Version Compatibility**: Separate implementations for Ruby 3.x and 4.0+
