;; fitnest-core
;; A smart contract that manages workout verification, tokenized rewards, and user achievement tracking
;; for the FitNest workout rewards platform on the Stacks blockchain.

;; ===================
;; Constants & Error Codes
;; ===================

;; Error codes
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-INVALID-WORKOUT (err u101))
(define-constant ERR-ORACLE-NOT-REGISTERED (err u102))
(define-constant ERR-DAILY-LIMIT-REACHED (err u103))
(define-constant ERR-ALREADY-VERIFIED (err u104))
(define-constant ERR-PROPOSAL-EXPIRED (err u105))
(define-constant ERR-INVALID-VOTE (err u106))
(define-constant ERR-INSUFFICIENT-TOKENS (err u107))
(define-constant ERR-PROPOSAL-NOT-ACTIVE (err u108))
(define-constant ERR-ALREADY-VOTED (err u109))

;; Workout types
(define-constant WORKOUT-TYPE-CARDIO u1)
(define-constant WORKOUT-TYPE-STRENGTH u2)
(define-constant WORKOUT-TYPE-FLEXIBILITY u3)
(define-constant WORKOUT-TYPE-HIIT u4)
(define-constant WORKOUT-TYPE-YOGA u5)

;; Achievement types
(define-constant ACHIEVEMENT-BEGINNER u1) ;; Complete 10 workouts
(define-constant ACHIEVEMENT-INTERMEDIATE u2) ;; Complete 50 workouts
(define-constant ACHIEVEMENT-ADVANCED u3) ;; Complete 100 workouts
(define-constant ACHIEVEMENT-STREAK-7 u4) ;; 7-day streak
(define-constant ACHIEVEMENT-STREAK-30 u5) ;; 30-day streak
(define-constant ACHIEVEMENT-VARIETY u6) ;; Try all workout types
(define-constant ACHIEVEMENT-DURATION u7) ;; 1000 total minutes

;; Governance constants
(define-constant VOTING-PERIOD-BLOCKS u144) ;; ~1 day at 10 min block times
(define-constant MIN-PROPOSAL-TOKENS u1000000000) ;; 1000 tokens (with 9 decimals)
(define-constant PROPOSAL-TYPE-NEW-WORKOUT u1)
(define-constant PROPOSAL-TYPE-REWARD-ADJUSTMENT u2)
(define-constant PROPOSAL-TYPE-NEW-ORACLE u3)

;; System parameters
(define-constant REWARD-BASE-AMOUNT u1000000000) ;; 1 token base reward (with 9 decimals)
(define-constant MAX-DAILY-WORKOUTS u3) ;; Maximum number of workouts per day

;; ===================
;; Data Maps & Variables
;; ===================

;; Contract owner
(define-data-var contract-owner principal tx-sender)

;; Authorized oracles (fitness tracking apps)
(define-map authorized-oracles principal bool)

;; User workout stats
(define-map user-stats
  { user: principal }
  {
    total-workouts: uint,
    total-minutes: uint, 
    current-streak: uint,
    longest-streak: uint,
    last-workout-day: uint,
    workouts-today: uint,
    workouts-by-type: (list 10 uint)
  }
)

;; Workout verification records
(define-map workout-verifications
  { workout-id: (buff 32), user: principal }
  {
    verified: bool,
    workout-type: uint,
    duration-minutes: uint,
    timestamp: uint,
    oracle: principal,
    rewarded: bool
  }
)

;; User achievements
(define-map user-achievements
  { user: principal, achievement-id: uint }
  { earned: bool, earned-at: uint }
)

;; Governance proposals
(define-map governance-proposals
  { proposal-id: uint }
  {
    proposer: principal,
    proposal-type: uint,
    description: (string-utf8 256),
    metadata: (buff 256),
    votes-for: uint,
    votes-against: uint,
    created-at-block: uint,
    executed: bool
  }
)

;; Vote tracking
(define-map proposal-votes
  { proposal-id: uint, voter: principal }
  { vote: bool }
)

;; Next proposal ID
(define-data-var next-proposal-id uint u1)

;; ===================
;; Private Functions
;; ===================

;; Initialize a new user's stats if they don't exist yet
(define-private (initialize-user-if-needed (user principal))
  (let ((exists (default-to false (get-user-stats-exists user))))
    (if exists
      true
      (map-set user-stats 
        { user: user }
        {
          total-workouts: u0,
          total-minutes: u0,
          current-streak: u0,
          longest-streak: u0,
          last-workout-day: u0,
          workouts-today: u0,
          workouts-by-type: (list u0 u0 u0 u0 u0 u0 u0 u0 u0 u0)
        }
      )
    )
  )
)

;; Check if user stats exist
(define-private (get-user-stats-exists (user principal))
  (map-has? user-stats { user: user })
)

;; Calculate reward amount based on workout type, duration, and streak
(define-private (calculate-reward (workout-type uint) (duration-minutes uint) (current-streak uint))
  (let (
    (type-multiplier (get-workout-type-multiplier workout-type))
    (duration-factor (/ duration-minutes u10))
    (streak-bonus (if (>= current-streak u5) 
                      (+ u100 (* (min u20 (/ current-streak u5)) u5))
                      u100))
  )
    (* (/ (* (* REWARD-BASE-AMOUNT type-multiplier) duration-factor) u100) streak-bonus)
  )
)

;; Get multiplier for different workout types
(define-private (get-workout-type-multiplier (workout-type uint))
  (match workout-type
    WORKOUT-TYPE-CARDIO u100
    WORKOUT-TYPE-STRENGTH u120
    WORKOUT-TYPE-FLEXIBILITY u90
    WORKOUT-TYPE-HIIT u150
    WORKOUT-TYPE-YOGA u110
    u100  ;; default multiplier
  )
)

;; Current day number (since Unix epoch, in days)
(define-private (get-current-day)
  (/ (unwrap-panic (get-block-info? time u0)) u86400)
)

;; Update user streak based on their last workout day
(define-private (update-user-streak (user principal))
  (let (
    (user-data (default-to 
                 {
                   total-workouts: u0,
                   total-minutes: u0,
                   current-streak: u0,
                   longest-streak: u0,
                   last-workout-day: u0,
                   workouts-today: u0,
                   workouts-by-type: (list u0 u0 u0 u0 u0 u0 u0 u0 u0 u0)
                 }
                 (map-get? user-stats { user: user })))
    (current-day (get-current-day))
    (last-day (get last-workout-day user-data))
  )
    (if (is-eq last-day u0)
      ;; First workout ever
      (map-set user-stats
        { user: user }
        (merge user-data {
          current-streak: u1,
          longest-streak: u1,
          last-workout-day: current-day
        })
      )
      (if (is-eq last-day current-day)
        ;; Already worked out today, streak unchanged
        true
        (if (is-eq last-day (- current-day u1))
          ;; Consecutive day, increment streak
          (let (
            (new-streak (+ (get current-streak user-data) u1))
            (new-longest (max (get longest-streak user-data) new-streak))
          )
            (map-set user-stats
              { user: user }
              (merge user-data {
                current-streak: new-streak,
                longest-streak: new-longest,
                last-workout-day: current-day,
                workouts-today: u1
              })
            )
          )
          ;; Missed a day, reset streak
          (map-set user-stats
            { user: user }
            (merge user-data {
              current-streak: u1,
              last-workout-day: current-day,
              workouts-today: u1
            })
          )
        )
      )
    )
  )
)

;; Update workout type counter for a user
(define-private (update-workout-type-counter (user principal) (workout-type uint))
  (let (
    (user-data (default-to 
                 {
                   total-workouts: u0,
                   total-minutes: u0,
                   current-streak: u0,
                   longest-streak: u0,
                   last-workout-day: u0,
                   workouts-today: u0,
                   workouts-by-type: (list u0 u0 u0 u0 u0 u0 u0 u0 u0 u0)
                 }
                 (map-get? user-stats { user: user })))
    (current-counts (get workouts-by-type user-data))
    (index (- workout-type u1))  ;; Convert type to 0-based index
  )
    (map-set user-stats
      { user: user }
      (merge user-data {
        workouts-by-type: (replace-at? current-counts index (+ (unwrap-panic (element-at? current-counts index)) u1))
      })
    )
  )
)

;; Check for and issue achievements to user
(define-private (check-achievements (user principal))
  (let (
    (user-data (default-to 
                 {
                   total-workouts: u0,
                   total-minutes: u0,
                   current-streak: u0,
                   longest-streak: u0,
                   last-workout-day: u0,
                   workouts-today: u0,
                   workouts-by-type: (list u0 u0 u0 u0 u0 u0 u0 u0 u0 u0)
                 }
                 (map-get? user-stats { user: user })))
    (total-workouts (get total-workouts user-data))
    (current-streak (get current-streak user-data))
    (longest-streak (get longest-streak user-data))
    (total-minutes (get total-minutes user-data))
    (workout-types (get workouts-by-type user-data))
  )
    (fold check-achievement-fold 
          (list 
            {achievement-id: ACHIEVEMENT-BEGINNER, threshold: u10, current: total-workouts}
            {achievement-id: ACHIEVEMENT-INTERMEDIATE, threshold: u50, current: total-workouts}
            {achievement-id: ACHIEVEMENT-ADVANCED, threshold: u100, current: total-workouts}
            {achievement-id: ACHIEVEMENT-STREAK-7, threshold: u7, current: longest-streak}
            {achievement-id: ACHIEVEMENT-STREAK-30, threshold: u30, current: longest-streak}
            {achievement-id: ACHIEVEMENT-DURATION, threshold: u1000, current: total-minutes}
          )
          { user: user }
    )
    
    ;; Check if user has tried all workout types (at least one of each)
    (let (
      (has-all-types (fold and-fold 
                           (map has-workout? (list u0 u1 u2 u3 u4)) 
                           true))
    )
      (if (and has-all-types 
               (is-none (map-get? user-achievements { user: user, achievement-id: ACHIEVEMENT-VARIETY })))
        (map-set user-achievements 
          { user: user, achievement-id: ACHIEVEMENT-VARIETY }
          { earned: true, earned-at: (unwrap-panic (get-block-info? time u0)) }
        )
        true
      )
    )
  )
)

;; Helper for check-achievements to process each achievement type
(define-private (check-achievement-fold (achievement-data {achievement-id: uint, threshold: uint, current: uint}) 
                                        (context {user: principal}))
  (if (and (>= (get current achievement-data) (get threshold achievement-data))
           (is-none (map-get? user-achievements 
                              { user: (get user context), 
                                achievement-id: (get achievement-id achievement-data) })))
    (map-set user-achievements 
      { user: (get user context), achievement-id: (get achievement-id achievement-data) }
      { earned: true, earned-at: (unwrap-panic (get-block-info? time u0)) }
    )
    true
  )
  context
)

;; Helper to check if user has completed a workout type
(define-private (has-workout? (index uint))
  (> (unwrap-panic (element-at? workout-types index)) u0)
)

;; Helper for combining booleans in fold
(define-private (and-fold (a bool) (b bool))
  (and a b)
)

;; ===================
;; Read-Only Functions
;; ===================

;; Get user stats
(define-read-only (get-user-stats (user principal))
  (map-get? user-stats { user: user })
)

;; Check if a workout has been verified
(define-read-only (is-workout-verified (workout-id (buff 32)) (user principal))
  (match (map-get? workout-verifications { workout-id: workout-id, user: user })
    verification (get verified verification)
    false
  )
)

;; Get user achievement status
(define-read-only (get-user-achievement (user principal) (achievement-id uint))
  (map-get? user-achievements { user: user, achievement-id: achievement-id })
)

;; Get all user achievements
(define-read-only (get-all-user-achievements (user principal))
  (let (
    (beginner (get-user-achievement user ACHIEVEMENT-BEGINNER))
    (intermediate (get-user-achievement user ACHIEVEMENT-INTERMEDIATE))
    (advanced (get-user-achievement user ACHIEVEMENT-ADVANCED))
    (streak-7 (get-user-achievement user ACHIEVEMENT-STREAK-7))
    (streak-30 (get-user-achievement user ACHIEVEMENT-STREAK-30))
    (variety (get-user-achievement user ACHIEVEMENT-VARIETY))
    (duration (get-user-achievement user ACHIEVEMENT-DURATION))
  )
    {
      beginner: beginner,
      intermediate: intermediate,
      advanced: advanced,
      streak-7: streak-7,
      streak-30: streak-30,
      variety: variety,
      duration: duration
    }
  )
)

;; Check if an oracle is registered
(define-read-only (is-oracle-registered (oracle principal))
  (default-to false (map-get? authorized-oracles oracle))
)

;; Get proposal details
(define-read-only (get-proposal (proposal-id uint))
  (map-get? governance-proposals { proposal-id: proposal-id })
)

;; Check if a proposal is active
(define-read-only (is-proposal-active (proposal-id uint))
  (match (get-proposal proposal-id)
    proposal (let (
      (start-block (get created-at-block proposal))
      (current-block (unwrap-panic (get-block-info? height u0)))
      (executed (get executed proposal))
    )
      (and (not executed)
           (<= current-block (+ start-block VOTING-PERIOD-BLOCKS))))
    false
  )
)

;; ===================
;; Public Functions
;; ===================

;; Register a new oracle (only contract owner)
(define-public (register-oracle (oracle principal))
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR-NOT-AUTHORIZED)
    (ok (map-set authorized-oracles oracle true))
  )
)

;; Remove an oracle (only contract owner)
(define-public (remove-oracle (oracle principal))
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR-NOT-AUTHORIZED)
    (ok (map-delete authorized-oracles oracle))
  )
)

;; Verify a workout completion (only callable by registered oracles)
(define-public (verify-workout 
  (user principal) 
  (workout-id (buff 32)) 
  (workout-type uint)
  (duration-minutes uint))
  (let (
    (oracle tx-sender)
    (current-time (unwrap-panic (get-block-info? time u0)))
    (current-day (get-current-day))
  )
    ;; Verify oracle is authorized
    (asserts! (is-oracle-registered oracle) ERR-ORACLE-NOT-REGISTERED)
    
    ;; Verify workout type is valid
    (asserts! (and (>= workout-type u1) (<= workout-type u5)) ERR-INVALID-WORKOUT)
    
    ;; Verify duration is sensible (between 5 and 180 minutes)
    (asserts! (and (>= duration-minutes u5) (<= duration-minutes u180)) ERR-INVALID-WORKOUT)
    
    ;; Check if this workout was already verified
    (asserts! (is-none (map-get? workout-verifications { workout-id: workout-id, user: user })) 
              ERR-ALREADY-VERIFIED)
    
    ;; Initialize user if needed
    (initialize-user-if-needed user)
    
    ;; Get user stats
    (let (
      (user-data (unwrap-panic (get-user-stats user)))
      (last-workout-day (get last-workout-day user-data))
    )
      ;; Check daily workout limit
      (if (is-eq last-workout-day current-day)
        (asserts! (< (get workouts-today user-data) MAX-DAILY-WORKOUTS) ERR-DAILY-LIMIT-REACHED)
        true
      )
      
      ;; Record workout verification
      (map-set workout-verifications
        { workout-id: workout-id, user: user }
        {
          verified: true,
          workout-type: workout-type,
          duration-minutes: duration-minutes,
          timestamp: current-time,
          oracle: oracle,
          rewarded: false
        }
      )
      
      ;; Update user stats
      (map-set user-stats
        { user: user }
        (merge user-data {
          total-workouts: (+ (get total-workouts user-data) u1),
          total-minutes: (+ (get total-minutes user-data) duration-minutes),
          workouts-today: (if (is-eq last-workout-day current-day)
                             (+ (get workouts-today user-data) u1)
                             u1)
        })
      )
      
      ;; Update streak
      (update-user-streak user)
      
      ;; Update workout type counter
      (update-workout-type-counter user workout-type)
      
      ;; Check for achievements
      (check-achievements user)
      
      ;; Calculate and issue rewards
      (let (
        (updated-user-data (unwrap-panic (get-user-stats user)))
        (reward-amount (calculate-reward 
                        workout-type
                        duration-minutes
                        (get current-streak updated-user-data)))
      )
        ;; Update workout as rewarded
        (map-set workout-verifications
          { workout-id: workout-id, user: user }
          (merge 
            (unwrap-panic (map-get? workout-verifications { workout-id: workout-id, user: user }))
            { rewarded: true }
          )
        )
        
        ;; Mint reward tokens to user
        (contract-call? .fitnest-token mint user reward-amount)
      )
    )
    (ok true)
  )
)

;; Create a governance proposal
(define-public (create-proposal 
  (proposal-type uint) 
  (description (string-utf8 256)) 
  (metadata (buff 256)))
  (let (
    (proposer tx-sender)
    (proposal-id (var-get next-proposal-id))
    (current-block (unwrap-panic (get-block-info? height u0)))
  )
    ;; Verify proposal type is valid
    (asserts! (and (>= proposal-type u1) (<= proposal-type u3)) ERR-INVALID-VOTE)
    
    ;; Check if user has enough tokens to propose
    (asserts! (>= (contract-call? .fitnest-token get-balance proposer) MIN-PROPOSAL-TOKENS) 
              ERR-INSUFFICIENT-TOKENS)
    
    ;; Store the proposal
    (map-set governance-proposals
      { proposal-id: proposal-id }
      {
        proposer: proposer,
        proposal-type: proposal-type,
        description: description,
        metadata: metadata,
        votes-for: u0,
        votes-against: u0,
        created-at-block: current-block,
        executed: false
      }
    )
    
    ;; Increment proposal ID
    (var-set next-proposal-id (+ proposal-id u1))
    
    (ok proposal-id)
  )
)

;; Vote on a governance proposal
(define-public (vote-on-proposal (proposal-id uint) (vote-for bool))
  (let (
    (voter tx-sender)
    (voting-power (contract-call? .fitnest-token get-balance voter))
  )
    ;; Check if proposal exists and is active
    (asserts! (is-proposal-active proposal-id) ERR-PROPOSAL-NOT-ACTIVE)
    
    ;; Check if user has already voted
    (asserts! (is-none (map-get? proposal-votes { proposal-id: proposal-id, voter: voter })) 
              ERR-ALREADY-VOTED)
    
    ;; Record the vote
    (map-set proposal-votes
      { proposal-id: proposal-id, voter: voter }
      { vote: vote-for }
    )
    
    ;; Update proposal vote counts
    (let (
      (proposal (unwrap! (get-proposal proposal-id) ERR-PROPOSAL-NOT-ACTIVE))
    )
      (map-set governance-proposals
        { proposal-id: proposal-id }
        (merge proposal {
          votes-for: (if vote-for (+ (get votes-for proposal) voting-power) (get votes-for proposal)),
          votes-against: (if vote-for (get votes-against proposal) (+ (get votes-against proposal) voting-power))
        })
      )
    )
    
    (ok true)
  )
)

;; Execute a proposal if voting period has ended and it passed
(define-public (execute-proposal (proposal-id uint))
  (let (
    (proposal (unwrap! (get-proposal proposal-id) ERR-PROPOSAL-NOT-ACTIVE))
    (current-block (unwrap-panic (get-block-info? height u0)))
  )
    ;; Check if voting period has ended
    (asserts! (> current-block (+ (get created-at-block proposal) VOTING-PERIOD-BLOCKS)) 
              ERR-PROPOSAL-NOT-ACTIVE)
    
    ;; Check if already executed
    (asserts! (not (get executed proposal)) ERR-PROPOSAL-ALREADY-EXECUTED)
    
    ;; Check if proposal passed (more votes for than against)
    (asserts! (> (get votes-for proposal) (get votes-against proposal)) ERR-PROPOSAL-REJECTED)
    
    ;; Mark proposal as executed
    (map-set governance-proposals
      { proposal-id: proposal-id }
      (merge proposal { executed: true })
    )
    
    ;; Execute the proposal based on its type
    (match (get proposal-type proposal)
      PROPOSAL-TYPE-NEW-WORKOUT (ok true) ;; Implementation would add new workout type
      PROPOSAL-TYPE-REWARD-ADJUSTMENT (ok true) ;; Implementation would adjust rewards
      PROPOSAL-TYPE-NEW-ORACLE 
        (let ((new-oracle (unwrap! (principal-of? (get metadata proposal)) ERR-INVALID-PROPOSAL-DATA)))
          (map-set authorized-oracles new-oracle true)
          (ok true)
        )
      (err ERR-INVALID-PROPOSAL-TYPE)
    )
  )
)

;; Transfer contract ownership (only current owner)
(define-public (transfer-ownership (new-owner principal))
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR-NOT-AUTHORIZED)
    (ok (var-set contract-owner new-owner))
  )
)