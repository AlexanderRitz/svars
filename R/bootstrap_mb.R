#'Bootstrap for IRFs of identified SVARs
#'
#'Calculating confidance bands for impulse response via moving block bootsrap
#'
#'@param x SVAR object of class "svars"
#'@param b.length Length of each block
#'@param horizon Time horizon of impulse response functions
#'@param nboot Number of bootstrap iterations
#'
#' @examples
#' \dontrun{
#' # data contains quarterly observations from 1965Q1 to 2008Q3
#' # x = output gap
#' # pi = inflation
#' # i = interest rates
#' set.seed(23211)
#' v1 <- VAR(USA, lag.max = 10, ic = "AIC" )
#' x1 <- id.ngml(v1)
#' summary(x1)
#'
#' # switching columns according to sign patter
#' x1$B <- x1$B[,c(3,2,1)]
#' x1$B[,3] <- x1$B[,3]*(-1)
#'
#' # impulse response analysis with confidence bands
#' bb <- mb.boot(x1, b.length = 15, nboot = 100, horizon = 30)
#' plot(bb, lowerq = 0.05, upperq = 0.95)
#' }
#'
#'@export


mb.boot <- function(x, b.length = 15, horizon, nboot){
  # x: vars object
  # B: estimated covariance matrix from true data set
  # horizon: Time horizon for Irf
  # nboot: number of bootstrap replications


  # function to create Z matrix
  y_lag_cr <- function(y, lag_length){
    # create matrix that stores the lags
    y_lag <- matrix(NA, dim(y)[1],dim(y)[2]*lag_length)
    for (i in 1:lag_length) {
      y_lag[(1+i):dim(y)[1],((i*NCOL(y)-NCOL(y))+1):(i*NCOL(y))] <- y[1:(dim(y)[1]-i),(1:NCOL(y))]
    }
    # drop first observation
    y_lag <- as.matrix(y_lag[-(1:lag_length),])
    out <- list(lags = y_lag)
  }

  sqrt.f <- function(Pstar, Sigma_u_star){
    yy <- suppressMessages(sqrtm(Sigma_u_hat_old))%*%solve(suppressMessages(sqrtm(Sigma_u_star)))%*%Pstar
    return(yy)
  }


  # gathering informations from vars object
  y <- x$y
  p <- x$p
  obs <- x$obs
  k <- x$K
  B <- x$B

  # calculating covariance from actual VAR
  A <- x$A_hat
  Z <- t(y_lag_cr(y, p)$lags)
  Z <-rbind(rep(1, ncol(Z)), Z)
  u <- t(y[-c(1:p),]) - A %*% Z
  Sigma_u_hat_old <- tcrossprod(u)/(obs - 1 - k * p)

  # creating new error terms
  errors <- list()

  # creating blocks
  N <- obs/b.length
  blocks <- array(NA, c(b.length, k, obs - b.length + 1))
  u <- t(u)
  for(i in 0:(obs-b.length)){
    blocks[,,(i+1)] <- u[(i+1):(i+b.length),]
  }

  for(i in 1:nboot){
    epsilon.star <- matrix(0, b.length*ceiling(N), ncol(u))
    epsilon.star <- list()
    # stacking randomly selected blocks at each other
    for(kk in 1:ceiling(N)){
      epsilon.star[[kk]] <- blocks[,,floor(runif(1, 1, obs-b.length+2))]
    }
    epsilon.star <- do.call('rbind', epsilon.star)

    # centering new errors
    for(s in 1:b.length){
      b.mean <- colSums(epsilon.star[1 : (s+(obs - b.length)),])/(obs - b.length +1)
      for(j in 0:floor(N)){
        epsilon.star[j*b.length + s,] <- epsilon.star[j*b.length + s,] - b.mean
      }
    }

    # cutting of unnecessary observations
    epsilon.star <- epsilon.star[1:obs,]

    errors[[i]] <- t(epsilon.star)
  }

  # Bootstrapfunction
  bootf <- function(Ustar1){

    Ystar <- as.data.frame(t(A %*% Z + Ustar1))
    varb <- VAR(Ystar, p = p)

    Sigma_u_star <- crossprod(residuals(varb))/(obs - 1 - k * p)

    if(x$method == "Non-Gaussian maximum likelihood"){
      temp <- id.ngml(varb)
    }else{
      temp <- id.cv(varb, SB = x$SB)
    }

    Pstar <- temp$B

    Pstar1 <- sqrt.f(Pstar, Sigma_u_star)
    diag_sigma_root <- diag(diag(suppressMessages(expm(B))))

    frobP <- frobICA_mod(t(solve(diag_sigma_root)%*%Pstar1), t(solve(diag_sigma_root)%*%B), standardize=TRUE)
    Pstar <- Pstar1%*%frobP$perm

    temp$B <- Pstar

    ip <- imrf(temp, horizon = horizon)
    return(ip)
  }

  bootstraps <- pblapply(errors, bootf)

  ## Impulse response of actual model
  ip <- imrf(x, horizon = horizon)

  result <- list(true = ip,
                 bootstrap = bootstraps)
  class(result) <- 'boot'
  return(result)
}

