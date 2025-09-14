;; Non-Custodial Bitcoin Vault
;; Provides timelocked withdrawals and enhanced security for Bitcoin holdings

;; Constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_UNAUTHORIZED (err u100))
(define-constant ERR_VAULT_NOT_FOUND (err u101))
(define-constant ERR_INSUFFICIENT_BALANCE (err u102))
(define-constant ERR_WITHDRAWAL_NOT_FOUND (err u103))
(define-constant ERR_WITHDRAWAL_NOT_PENDING (err u104))
(define-constant ERR_TIMELOCK_NOT_EXPIRED (err u105))
(define-constant ERR_INVALID_TIMELOCK (err u106))
(define-constant ERR_WITHDRAWAL_ALREADY_EXISTS (err u107))
(define-constant ERR_INVALID_AMOUNT (err u108))

;; Minimum and maximum timelock periods (in blocks)
(define-constant MIN_TIMELOCK_BLOCKS u144) ;; ~24 hours
(define-constant MAX_TIMELOCK_BLOCKS u1008) ;; ~7 days
(define-constant DEFAULT_TIMELOCK_BLOCKS u288) ;; ~48 hours

;; Data structures
(define-map vaults
  { owner: principal }
  {
    balance: uint,
    timelock-blocks: uint,
    created-at: uint,
    total-deposits: uint,
    total-withdrawals: uint
  }
)

(define-map withdrawal-requests
  { vault-owner: principal, request-id: uint }
  {
    amount: uint,
    recipient: (string-ascii 64),
    requested-at: uint,
    status: (string-ascii 20), ;; "pending", "cancelled", "executed"
    timelock-expires-at: uint
  }
)

(define-map vault-withdrawal-counters
  { owner: principal }
  { counter: uint }
)

;; Data variables
(define-data-var total-vaults uint u0)

;; Events
(define-data-var last-event-id uint u0)

;; Private functions

(define-private (get-next-withdrawal-id (vault-owner principal))
  (let ((current-counter (default-to u0 (get counter (map-get? vault-withdrawal-counters { owner: vault-owner })))))
    (let ((next-id (+ current-counter u1)))
      (map-set vault-withdrawal-counters { owner: vault-owner } { counter: next-id })
      next-id
    )
  )
)

(define-private (is-valid-timelock (blocks uint))
  (and 
    (>= blocks MIN_TIMELOCK_BLOCKS)
    (<= blocks MAX_TIMELOCK_BLOCKS)
  )
)

;; Public functions

;; Create a new vault with specified timelock period
(define-public (create-vault (timelock-blocks uint))
  (let ((vault-owner tx-sender))
    (asserts! (is-none (map-get? vaults { owner: vault-owner })) ERR_VAULT_NOT_FOUND)
    (asserts! (is-valid-timelock timelock-blocks) ERR_INVALID_TIMELOCK)
    
    (map-set vaults 
      { owner: vault-owner }
      {
        balance: u0,
        timelock-blocks: timelock-blocks,
        created-at: stacks-block-height,
        total-deposits: u0,
        total-withdrawals: u0
      }
    )
    
    (var-set total-vaults (+ (var-get total-vaults) u1))
    (print { 
      event: "vault-created", 
      owner: vault-owner, 
      timelock-blocks: timelock-blocks,
      created-at: stacks-block-height
    })
    (ok true)
  )
)

;; Register a Bitcoin deposit (called when BTC is detected)
(define-public (register-deposit (amount uint))
  (let (
    (vault-owner tx-sender)
    (vault-data (unwrap! (map-get? vaults { owner: vault-owner }) ERR_VAULT_NOT_FOUND))
  )
    (asserts! (> amount u0) ERR_INVALID_AMOUNT)
    
    (map-set vaults
      { owner: vault-owner }
      (merge vault-data {
        balance: (+ (get balance vault-data) amount),
        total-deposits: (+ (get total-deposits vault-data) amount)
      })
    )
    
    (print { 
      event: "deposit-registered", 
      owner: vault-owner, 
      amount: amount,
      new-balance: (+ (get balance vault-data) amount)
    })
    (ok true)
  )
)

;; Request a withdrawal (starts the timelock period)
(define-public (request-withdrawal (amount uint) (recipient (string-ascii 64)))
  (let (
    (vault-owner tx-sender)
    (vault-data (unwrap! (map-get? vaults { owner: vault-owner }) ERR_VAULT_NOT_FOUND))
    (request-id (get-next-withdrawal-id vault-owner))
    (timelock-expires-at (+ stacks-block-height (get timelock-blocks vault-data)))
  )
    (asserts! (> amount u0) ERR_INVALID_AMOUNT)
    (asserts! (>= (get balance vault-data) amount) ERR_INSUFFICIENT_BALANCE)
    
    ;; Check if there's already a pending withdrawal
    (asserts! 
      (is-none (map-get? withdrawal-requests { vault-owner: vault-owner, request-id: request-id }))
      ERR_WITHDRAWAL_ALREADY_EXISTS
    )
    
    (map-set withdrawal-requests
      { vault-owner: vault-owner, request-id: request-id }
      {
        amount: amount,
        recipient: recipient,
        requested-at: stacks-block-height,
        status: "pending",
        timelock-expires-at: timelock-expires-at
      }
    )
    
    (print { 
      event: "withdrawal-requested", 
      owner: vault-owner, 
      request-id: request-id,
      amount: amount,
      recipient: recipient,
      timelock-expires-at: timelock-expires-at
    })
    (ok request-id)
  )
)

;; Cancel a pending withdrawal
(define-public (cancel-withdrawal (request-id uint))
  (let (
    (vault-owner tx-sender)
    (withdrawal-data (unwrap! (map-get? withdrawal-requests { vault-owner: vault-owner, request-id: request-id }) ERR_WITHDRAWAL_NOT_FOUND))
  )
    (asserts! (is-eq (get status withdrawal-data) "pending") ERR_WITHDRAWAL_NOT_PENDING)
    
    (map-set withdrawal-requests
      { vault-owner: vault-owner, request-id: request-id }
      (merge withdrawal-data { status: "cancelled" })
    )
    
    (print { 
      event: "withdrawal-cancelled", 
      owner: vault-owner, 
      request-id: request-id,
      amount: (get amount withdrawal-data)
    })
    (ok true)
  )
)

;; Execute a withdrawal after timelock expires
(define-public (execute-withdrawal (request-id uint))
  (let (
    (vault-owner tx-sender)
    (vault-data (unwrap! (map-get? vaults { owner: vault-owner }) ERR_VAULT_NOT_FOUND))
    (withdrawal-data (unwrap! (map-get? withdrawal-requests { vault-owner: vault-owner, request-id: request-id }) ERR_WITHDRAWAL_NOT_FOUND))
  )
    (asserts! (is-eq (get status withdrawal-data) "pending") ERR_WITHDRAWAL_NOT_PENDING)
    (asserts! (>= stacks-block-height (get timelock-expires-at withdrawal-data)) ERR_TIMELOCK_NOT_EXPIRED)
    (asserts! (>= (get balance vault-data) (get amount withdrawal-data)) ERR_INSUFFICIENT_BALANCE)
    
    ;; Update vault balance
    (map-set vaults
      { owner: vault-owner }
      (merge vault-data {
        balance: (- (get balance vault-data) (get amount withdrawal-data)),
        total-withdrawals: (+ (get total-withdrawals vault-data) (get amount withdrawal-data))
      })
    )
    
    ;; Mark withdrawal as executed
    (map-set withdrawal-requests
      { vault-owner: vault-owner, request-id: request-id }
      (merge withdrawal-data { status: "executed" })
    )
    
    (print { 
      event: "withdrawal-executed", 
      owner: vault-owner, 
      request-id: request-id,
      amount: (get amount withdrawal-data),
      recipient: (get recipient withdrawal-data),
      new-balance: (- (get balance vault-data) (get amount withdrawal-data))
    })
    (ok true)
  )
)

;; Update vault timelock period
(define-public (update-timelock (new-timelock-blocks uint))
  (let (
    (vault-owner tx-sender)
    (vault-data (unwrap! (map-get? vaults { owner: vault-owner }) ERR_VAULT_NOT_FOUND))
  )
    (asserts! (is-valid-timelock new-timelock-blocks) ERR_INVALID_TIMELOCK)
    
    (map-set vaults
      { owner: vault-owner }
      (merge vault-data { timelock-blocks: new-timelock-blocks })
    )
    
    (print { 
      event: "timelock-updated", 
      owner: vault-owner, 
      old-timelock: (get timelock-blocks vault-data),
      new-timelock: new-timelock-blocks
    })
    (ok true)
  )
)

;; Read-only functions

(define-read-only (get-vault-info (owner principal))
  (map-get? vaults { owner: owner })
)

(define-read-only (get-withdrawal-request (vault-owner principal) (request-id uint))
  (map-get? withdrawal-requests { vault-owner: vault-owner, request-id: request-id })
)

(define-read-only (get-vault-balance (owner principal))
  (match (map-get? vaults { owner: owner })
    vault-data (ok (get balance vault-data))
    ERR_VAULT_NOT_FOUND
  )
)

(define-read-only (get-total-vaults)
  (var-get total-vaults)
)

(define-read-only (is-withdrawal-ready (vault-owner principal) (request-id uint))
  (match (map-get? withdrawal-requests { vault-owner: vault-owner, request-id: request-id })
    withdrawal-data 
      (and 
        (is-eq (get status withdrawal-data) "pending")
        (>= stacks-block-height (get timelock-expires-at withdrawal-data))
      )
    false
  )
)

(define-read-only (get-withdrawal-counter (owner principal))
  (default-to u0 (get counter (map-get? vault-withdrawal-counters { owner: owner })))
)
