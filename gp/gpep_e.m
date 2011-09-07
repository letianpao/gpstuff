function [e, edata, eprior, tautilde, nutilde, L, La2, b, muvec_i, sigm2vec_i, Z_i, eta] = gpep_e(w, gp, varargin)
%GPEP_E  Do Expectation propagation and return marginal log posterior estimate
%
%  Description
%    E = GPEP_E(W, GP, X, Y, OPTIONS) takes a GP structure GP
%    together with a matrix X of input vectors and a matrix Y of
%    target vectors, and finds the EP approximation for the
%    conditional posterior p(Y | X, th), where th is the
%    parameters. Returns the energy at th (see below). Each row of
%    X corresponds to one input vector and each row of Y
%    corresponds to one target vector.
%
%    [E, EDATA, EPRIOR] = GPEP_E(W, GP, X, Y, OPTIONS) returns also
%    the data and prior components of the total energy.
%
%    The energy is minus log posterior cost function for th:
%      E = EDATA + EPRIOR 
%        = - log p(Y|X, th) - log p(th),
%      where th represents the parameters (lengthScale,
%      magnSigma2...), X is inputs and Y is observations.
%
%    OPTIONS is optional parameter-value pair
%      z - optional observed quantity in triplet (x_i,y_i,z_i)
%          Some likelihoods may use this. For example, in case of
%          Poisson likelihood we have z_i=E_i, that is, expected
%          value for ith case.
%
%  See also
%    GP_SET, GP_E, GPEP_G, GPEP_PRED

%  Description 2
%    Additional properties meant only for internal use.
%  
%    GP = GPEP_E('init', GP) takes a GP structure GP and
%    initializes required fields for the EP algorithm.
%
%    GPEP_E('clearcache', GP) takes a GP structure GP and cleares
%    the internal cache stored in the nested function workspace
%
%    [e, edata, eprior, site_tau, site_nu, L, La2, b, muvec_i, sigm2vec_i]
%      = GPEP_E(w, gp, x, y, options)
%    returns many useful quantities produced by EP algorithm.
%
  
% Copyright (c) 2007  Jaakko Riihim�ki
% Copyright (c) 2007-2010  Jarno Vanhatalo
% Copyright (c) 2010 Heikki Peura
% Copyright (c) 2010-2011 Aki Vehtari

% This software is distributed under the GNU General Public
% License (version 3 or later); please refer to the file
% License.txt, included with the software, for details.
  
% parse inputs
  ip=inputParser;
  ip.FunctionName = 'GPEP_E';
  ip.addRequired('w', @(x) ...
                 isempty(x) || ...
                 (ischar(x) && ismember(x, {'init' 'clearcache'})) || ...
                 (isvector(x) && isreal(x) && all(isfinite(x))) || ...
                 isnan(x));
  ip.addRequired('gp',@isstruct);
  ip.addOptional('x', [], @(x) isnumeric(x) && isreal(x) && all(isfinite(x(:))))
  ip.addOptional('y', [], @(x) isnumeric(x) && isreal(x) && all(isfinite(x(:))))
  ip.addParamValue('z', [], @(x) isnumeric(x) && isreal(x) && all(isfinite(x(:))))
  ip.parse(w, gp, varargin{:});
  x=ip.Results.x;
  y=ip.Results.y;
  z=ip.Results.z;
  
  if strcmp(w, 'init')
    % intialize cache
    ch = [];
    
    % return function handle to the nested function ep_algorithm
    % this way each gp has its own peristent memory for EP
    gp.fh.e = @ep_algorithm;
    e = gp;
    % remove clutter from the nested workspace
    clear w gp varargin ip x y z
  elseif strcmp(w, 'clearcache')
    % clear the cache
    gp.fh.e('clearcache');
  else
    % call ep_algorithm using the function handle to the nested function
    % this way each gp has its own peristent memory for EP
    [e, edata, eprior, tautilde, nutilde, L, La2, b, muvec_i, sigm2vec_i, Z_i, eta] = gp.fh.e(w, gp, x, y, z);
  end

  function [e, edata, eprior, tautilde, nutilde, L, La2, b, muvec_i, sigm2vec_i, Z_i, eta] = ep_algorithm(w, gp, x, y, z)
    
    if strcmp(w, 'clearcache')
      ch=[];
      return
    end
    
    switch gp.latent_opt.optim_method
      
      case 'basic-EP'
        
        % check whether saved values can be used
        if isempty(z)
          datahash=hash_sha512([x y]);
        else
          datahash=hash_sha512([x y z]);
        end
        if ~isempty(ch) && all(size(w)==size(ch.w)) && all(abs(w-ch.w)<1e-8) && isequal(datahash,ch.datahash)
          % The covariance function parameters or data haven't changed
          % so we can return the energy and the site parameters that are saved
          e = ch.e;
          edata = ch.edata;
          eprior = ch.eprior;
          tautilde = ch.tautilde;
          nutilde = ch.nutilde;
          L = ch.L;
          La2 = ch.La2;
          b = ch.b;
          muvec_i = ch.muvec_i;
          sigm2vec_i = ch.sigm2vec_i;
          Z_i = ch.Z_i;
          eta = ch.eta;
        else
          % The parameters or data have changed since
          % the last call for gpep_e. In this case we need to
          % re-evaluate the EP approximation
          gp=gp_unpak(gp, w);
          ncf = length(gp.cf);
          n = size(x,1);
          
          % EP iteration parameters
          iter=1;
          maxiter = gp.latent_opt.maxiter;
          tol = gp.latent_opt.tol;
          nutilde = zeros(size(y));
          tautilde = zeros(size(y));
          logZep_tmp=0; logZep=Inf;
          if ~isfield(gp,'meanf')
            myy = zeros(size(y));
          else
            [H,b_m,B_m]=mean_prep(gp,x,[]);
            myy = H'*b_m;
          end
          
          M0 = [];
          
          % =================================================
          % First Evaluate the data contribution to the error
          switch gp.type
            % ============================================================
            % FULL
            % ============================================================
            case 'FULL'   % A full GP
              [K,C] = gp_trcov(gp, x);
              
              % The EP algorithm for full support covariance function
              %------------------------------------------------------
              if ~issparse(C)
                if ~isfield(gp,'meanf')
                  Sigm = C;
                else
                  Sigm = C + H'*B_m*H;
                end
                [Ls, notpositivedefinite] = chol(Sigm);
                if notpositivedefinite
                  [e, edata, eprior, tautilde, nutilde, L, La2, b, muvec_i, sigm2vec_i, Z_i, eta, ch] = set_output_for_notpositivedefinite();
                  return
                end
                Stildesqroot=zeros(n);
                
                % If Student-t likelihood is used, sort the update order so that
                % the problematic updates are left for last
                if strcmp(gp.lik.type,'Student-t')
                  f=gp.lik.fh.optimizef(gp,y,K);
                  W=-gp.lik.fh.llg2(gp.lik,y,f,'latent');
                  [foo,I]=sort(W,'descend');
                else
                  I=1:n;
                end
                
                % The EP -algorithm
                while iter<=maxiter && abs(logZep_tmp-logZep)>tol
                  logZep_tmp=logZep;
                  muvec_i = zeros(n,1); sigm2vec_i = zeros(n,1);
                  
                  for ii=1:n
                    i1 = I(ii);
                    % Algorithm utilizing Cholesky updates
                    % This is numerically more stable but slower
                    % $$$                             % approximate cavity parameters
                    % $$$                             S11 = sum(Ls(:,i1).^2);
                    % $$$                             S1 = Ls'*Ls(:,i1);
                    % $$$                             tau_i=S11^-1-tautilde(i1);
                    % $$$                             vee_i=S11^-1*myy(i1)-nutilde(i1);
                    % $$$
                    % $$$                             myy_i=vee_i/tau_i;
                    % $$$                             sigm2_i=tau_i^-1;
                    % $$$
                    % $$$                             if sigm2_i < 0
                    % $$$                                 [ii i1]
                    % $$$                             end
                    % $$$
                    % $$$                             % marginal moments
                    % $$$                             [M0(i1), muhati, sigm2hati] = feval(gp.lik.fh.tiltedMoments, gp.lik, y, i1, sigm2_i, myy_i, z);
                    % $$$
                    % $$$                             % update site parameters
                    % $$$                             deltatautilde = sigm2hati^-1-tau_i-tautilde(i1);
                    % $$$                             tautilde(i1) = tautilde(i1)+deltatautilde;
                    % $$$                             nutilde(i1) = sigm2hati^-1*muhati-vee_i;
                    % $$$
                    % $$$                             upfact = 1./(deltatautilde^-1+S11);
                    % $$$                             if upfact > 0
                    % $$$                                 Ls = cholupdate(Ls, S1.*sqrt(upfact), '-');
                    % $$$                             else
                    % $$$                                 Ls = cholupdate(Ls, S1.*sqrt(-upfact));
                    % $$$                             end
                    % $$$                             Sigm = Ls'*Ls;
                    % $$$                             myy=Sigm*nutilde;
                    % $$$
                    % $$$                             muvec_i(i1,1)=myy_i;
                    % $$$                             sigm2vec_i(i1,1)=sigm2_i;
                    
                    % Algorithm as in Rasmussen and Williams 2006
                    % approximate cavity parameters
                    tau_i=Sigm(i1,i1)^-1-tautilde(i1);
                    vee_i = Sigm(i1,i1)^-1*myy(i1)-nutilde(i1);
                    
                    if tau_i < 0
                      tautilde(find(tautilde<0)) = 0;
                      
                      Stilde=tautilde;
                      Stildesqroot=diag(sqrt(tautilde));
                      B=eye(n)+Stildesqroot*C*Stildesqroot;
                      [L, notpositivedefinite]=chol(B,'lower');
                      if notpositivedefinite
                        [e, edata, eprior, tautilde, nutilde, L, La2, b, muvec_i, sigm2vec_i, Z_i, eta, ch] = set_output_for_notpositivedefinite();
                        return
                      end
                      V=(L\Stildesqroot)*C;
                      Sigm=C-V'*V;
                      nutilde=Sigm\myy;
                      
                      tau_i=Sigm(i1,i1)^-1-tautilde(i1);
                      vee_i=Sigm(i1,i1)^-1*myy(i1)-nutilde(i1);
                      
                      if isfield(gp.latent_opt, 'display') && gp.latent_opt.display
                        fprintf('negative cavity at site %d \n', i1)
                      end
                    end
                    myy_i=vee_i/tau_i;
                    sigm2_i=tau_i^-1;
                    
                    % marginal moments
                    [M0(i1), muhati, sigm2hati] = gp.lik.fh.tiltedMoments(gp.lik, y, i1, sigm2_i, myy_i, z);
                    
                    % update site parameters
                    deltatautilde=sigm2hati^-1-tau_i-tautilde(i1);
                    tautilde(i1)=tautilde(i1)+deltatautilde;
                    nutilde(i1)=sigm2hati^-1*muhati-vee_i;
                    
                    % Update mean and variance after each site update (standard EP)
                    if isequal(gp.latent_opt.parallel,'off')
                      apu = deltatautilde/(1+deltatautilde*Sigm(i1,i1));
                      Sigm = Sigm - apu*(Sigm(:,i1)*Sigm(:,i1)');
                      
                      % The below is how Rasmussen and Williams
                      % (2006) do the update. The above version is
                      % more robust.
                      %apu = deltatautilde^-1+Sigm(i1,i1);
                      %apu = (Sigm(:,i1)/apu)*Sigm(:,i1)';
                      %Sigm = Sigm - apu;
                      %Sigm=Sigm-(deltatautilde^-1+Sigm(i1,i1))^-1*(Sigm(:,i1)*Sigm(:,i1)');
                      if ~isfield(gp,'meanf')
                        myy=Sigm*nutilde;
                      else
                        myy=Sigm*(C\(H'*b_m)+nutilde);
                      end
                    else
                      % Parallel EP
                      % Update myy & Sigm after all site parameters are
                      % calculated
                    end
                    
                    muvec_i(i1,1)=myy_i;
                    sigm2vec_i(i1,1)=sigm2_i;
                  end
                  % Recompute the approximate posterior parameters
                  if tautilde > 0
                    % This is the usual case where likelihood is log concave
                    % for example, Poisson and probit
                    
                    Stilde=tautilde;
                    Stildesqroot=diag(sqrt(tautilde));
                    
                    if ~isfield(gp,'meanf')  % zero mean function used
                      
                      % NOTICE! upper triangle matrix! cf. to
                      % line 13 in the algorithm 3.5, p. 58.
                      
                      B=eye(n)+Stildesqroot*C*Stildesqroot;
                      [L,notpositivedefinite] = chol(B,'lower');
                      if notpositivedefinite
                        [e, edata, eprior, tautilde, nutilde, L, La2, b, muvec_i, sigm2vec_i, Z_i, eta, ch] = set_output_for_notpositivedefinite();
                        return
                      end
                      V=(L\Stildesqroot)*C;
                      Sigm=C-V'*V; myy=Sigm*nutilde;
                      [Ls, notpositivedefinite] = chol(Sigm);
                      if notpositivedefinite
                        [e, edata, eprior, tautilde, nutilde, L, La2, b, muvec_i, sigm2vec_i, Z_i, eta, ch] = set_output_for_notpositivedefinite();
                        return
                      end
                      
                      % Compute the marginal likelihood
                      % Direct formula (3.65):
                      % Sigmtilde=diag(1./tautilde);
                      % mutilde=inv(Stilde)*nutilde;
                      %
                      % logZep=-0.5*log(det(Sigmtilde+K))-0.5*mutilde'*inv(K+Sigmtilde)*mutilde+
                      %         sum(log(normcdf(y.*muvec_i./sqrt(1+sigm2vec_i))))+
                      %         0.5*sum(log(sigm2vec_i+1./tautilde))+
                      %         sum((muvec_i-mutilde).^2./(2*(sigm2vec_i+1./tautilde)))
                      
                      % 4. term & 1. term
                      term41=0.5*sum(log(1+tautilde.*sigm2vec_i))-sum(log(diag(L)));
                      
                      % 5. term (1/2 element) & 2. term
                      T=1./sigm2vec_i;
                      Cnutilde = C*nutilde;
                      L2 = V*nutilde;
                      term52 = nutilde'*Cnutilde - L2'*L2 - (nutilde'./(T+Stilde)')*nutilde;
                      term52 = term52.*0.5;
                      
                      % 5. term (2/2 element)
                      term5=0.5*muvec_i'.*(T./(Stilde+T))'*(Stilde.*muvec_i-2*nutilde);
                      
                      % 3. term
                      term3 = sum(log(M0));
                      
                      logZep = -(term41+term52+term5+term3);
                      iter=iter+1;
                      
                    else
                      % mean function used
                      % help variables
                      hBh = H'*B_m*H;
                      C_t = C + hBh;
                      CHb  = C\H'*b_m;
                      S   = Stildesqroot.^2;
                      B = eye(n)+Stildesqroot*C*Stildesqroot;
                      B_h = eye(n) + Stildesqroot*C_t*Stildesqroot;
                      % L to return, without the hBh term
                      [L,notpositivedefinite]=chol(B,'lower');
                      if notpositivedefinite
                        [e, edata, eprior, tautilde, nutilde, L, La2, b, muvec_i, sigm2vec_i, Z_i, eta, ch] = set_output_for_notpositivedefinite();
                        return
                      end
                      % L for the calculation with mean term
                      [L_m,notpositivedefinite]=chol(B_h,'lower');
                      if notpositivedefinite
                        [e, edata, eprior, tautilde, nutilde, L, La2, b, muvec_i, sigm2vec_i, Z_i, eta, ch] = set_output_for_notpositivedefinite();
                        return
                      end
                      
                      % Recompute the approximate posterior
                      % parameters
                      V=(L_m\Stildesqroot)*C_t;
                      Sigm=C_t-V'*V; myy=Sigm*(CHb+nutilde);
                      
                      
                      [Ls, notpositivedefinite] = chol(Sigm);
                      if notpositivedefinite
                        [e, edata, eprior, tautilde, nutilde, L, La2, b, muvec_i, sigm2vec_i, Z_i, eta, ch] = set_output_for_notpositivedefinite();
                        return
                      end
                      T=1./sigm2vec_i;
                      Cnutilde = (C_t - S^-1)*(S*H'*b_m-nutilde);
                      L2 = V*(S*H'*b_m-nutilde);
                      
                      zz   = Stildesqroot*(L'\(L\(Stildesqroot*C)));
                      % inv(K + S^-1)*S^-1
                      Ks  = eye(size(zz)) - zz;
                      
                      % 5. term (1/2 element)
                      term5_1  = 0.5.*((nutilde'*S^-1)./(T.^-1+Stilde.^-1)')*(S^-1*nutilde);
                      % 2. term
                      term2    = 0.5.*((S*H'*b_m-nutilde)'*Cnutilde - L2'*L2);
                      % 4. term
                      term4    = 0.5*sum(log(1+tautilde.*sigm2vec_i));
                      % 1. term
                      term1    = -1.*sum(log(diag(L_m)));
                      % 3. term
                      term3    = sum(log(M0));
                      % 5. term (2/2 element)
                      term5    = 0.5*muvec_i'.*(T./(Stilde+T))'*(Stilde.*muvec_i-2*nutilde);
                      
                      logZep = -(term4+term1+term5_1+term5+term2+term3);
                      iter=iter+1;
                      
                    end
                    
                    %==============================
                    
                  else
                    % We might end up here if the likelihood is not log concace
                    % For example Student-t likelihood.
                    % NOTE! This does not work reliably yet
                    Stilde=tautilde;
                    [Ls, notpositivedefinite] = chol(Sigm);
                    if notpositivedefinite
                      [e, edata, eprior, tautilde, nutilde, L, La2, b, muvec_i, sigm2vec_i, Z_i, eta, ch] = set_output_for_notpositivedefinite();
                      return
                    end
                    myy=Sigm*nutilde;
                    
                    % Compute the marginal likelihood
                    % 4. term & 1. term
                    [~, notpositivedefinite] = chol(C);
                    if notpositivedefinite
                      [e, edata, eprior, tautilde, nutilde, L, La2, b, muvec_i, sigm2vec_i, Z_i, eta, ch] = set_output_for_notpositivedefinite();
                      return
                    end
                    term41 = 0.5*sum(log(1+tautilde.*sigm2vec_i)) - sum(log(diag(chol(C)))) + sum(log(diag(Ls)));
                    
                    % 5. term (1/2 element) & 2. term
                    T=1./sigm2vec_i;
                    term52 = nutilde'*(Ls'*(Ls*nutilde)) - (nutilde'./(T+Stilde)')*nutilde;
                    term52 = term52.*0.5;
                    
                    % 5. term (2/2 element)
                    term5=0.5*muvec_i'.*(T./(Stilde+T))'*(Stilde.*muvec_i-2*nutilde);
                    
                    % 3. term
                    term3 = sum(log(M0));
                    
                    logZep = -(term41+term52+term5+term3);
                    iter=iter+1;
                    B=Ls;
                    L=Ls;
                    
                  end
                end
                % EP algorithm for compactly supported covariance function (that is
                % C is sparse)
                %------------------------------------------------------------------
              else
                p = analyze(K);
                r(p) = 1:n;
                if ~isempty(z)
                  z = z(p,:);
                end
                y = y(p);
                K = K(p,p);
                
                Inn = sparse(1:n,1:n,1,n,n);
                sqrtS = sparse(1:n,1:n,0,n,n);
                myy = zeros(size(y));
                sigm2 = zeros(size(y));
                gamma = zeros(size(y));
                [VD, notpositivedefinite] = ldlchol(Inn);
                if notpositivedefinite
                  [e, edata, eprior, tautilde, nutilde, L, La2, b, muvec_i, sigm2vec_i, Z_i, eta, ch] = set_output_for_notpositivedefinite();
                  return
                end
                
                
                % The EP -algorithm
                while iter<=maxiter && abs(logZep_tmp-logZep)>tol
                  
                  logZep_tmp=logZep;
                  muvec_i = zeros(n,1); sigm2vec_i = zeros(n,1);
                  for i1=1:n
                    % approximate cavity parameters
                    Ki1 = K(:,i1);
                    sqrtSKi1 = ssmult(sqrtS, Ki1);
                    tttt = ldlsolve(VD,sqrtSKi1);
                    sigm2(i1) = Ki1(i1) - sqrtSKi1'*tttt;
                    myy(i1) = gamma(i1) - tttt'*sqrtS*gamma;
                    
                    tau_i=sigm2(i1)^-1-tautilde(i1);
                    vee_i=sigm2(i1)^-1*myy(i1)-nutilde(i1);
                    
                    myy_i=vee_i/tau_i;
                    sigm2_i=tau_i^-1;
                    
                    % marginal moments
                    [M0(i1), muhati, sigm2hati] = gp.lik.fh.tiltedMoments(gp.lik, y, i1, sigm2_i, myy_i, z);
                    
                    % update site parameters
                    tautilde_old = tautilde(i1);
                    deltatautilde=sigm2hati^-1-tau_i-tautilde(i1);
                    tautilde(i1)=tautilde(i1)+deltatautilde;
                    nutilde_old = nutilde(i1);
                    nutilde(i1)=sigm2hati^-1*muhati-vee_i;
                    deltanutilde = nutilde(i1) - nutilde_old;
                    
                    % Update the LDL decomposition
                    sqrtS(i1,i1) = sqrt(tautilde(i1));
                    sqrtSKi1(i1) = sqrt(tautilde(i1)).*Ki1(i1);
                    D2_n = sqrtSKi1.*sqrtS(i1,i1) + Inn(:,i1);
                    
                    if tautilde_old == 0
                      VD = ldlrowupdate(i1,VD,VD(:,i1),'-');
                      VD = ldlrowupdate(i1,VD,D2_n,'+');
                    else
                      VD = ldlrowmodify(VD, D2_n, i1);
                    end
                    gamma = gamma + Ki1.*deltanutilde;
                    
                    muvec_i(i1,1)=myy_i;
                    sigm2vec_i(i1,1)=sigm2_i;
                  end
                  % Recompute the approximate posterior parameters
                  sqrtS = sparse(1:n,1:n,sqrt(tautilde),n,n);
                  KsqrtS = ssmult(K,sqrtS);
                  B = ssmult(sqrtS,KsqrtS) + Inn;
                  [VD, notpositivedefinite] = ldlchol(B);
                  if notpositivedefinite
                    [e, edata, eprior, tautilde, nutilde, L, La2, b, muvec_i, sigm2vec_i, Z_i, eta, ch] = set_output_for_notpositivedefinite();
                    return
                  end
                  Knutilde = K*nutilde;
                  myy = Knutilde - KsqrtS*ldlsolve(VD,sqrtS*Knutilde);
                  
                  % Compute the marginal likelihood
                  % 4. term & 1. term
                  term41=0.5*sum(log(1+tautilde.*sigm2vec_i)) - 0.5.*sum(log(diag(VD)));
                  
                  % 5. term (1/2 element) & 2. term
                  T=1./sigm2vec_i;
                  term52 = nutilde'*myy - (nutilde'./(T+tautilde)')*nutilde;
                  term52 = term52.*0.5;
                  
                  % 5. term (2/2 element)
                  term5=0.5*muvec_i'.*(T./(tautilde+T))'*(tautilde.*muvec_i-2*nutilde);
                  
                  % 3. term
                  term3 = sum(log(M0));
                  
                  logZep = -(term41+term52+term5+term3);
                  
                  iter=iter+1;
                  
                end
                % Reorder all the returned and stored values
                
                B = B(r,r);
                nutilde = nutilde(r);
                tautilde = tautilde(r);
                myy = myy(r);
                y = y(r);
                if ~isempty(z)
                  z = z(r,:);
                end
                [L, notpositivedefinite] = ldlchol(B);
                if notpositivedefinite
                  [e, edata, eprior, tautilde, nutilde, L, La2, b, muvec_i, sigm2vec_i, Z_i, eta, ch] = set_output_for_notpositivedefinite();
                  return
                end
                
              end
              edata = logZep;
              % Set something into La2
              La2 = B;
              b = 0;
              
              % ============================================================
              % FIC
              % ============================================================
            case 'FIC'
              u = gp.X_u;
              m = size(u,1);
              
              % First evaluate needed covariance matrices
              % v defines that parameter is a vector
              [Kv_ff, Cv_ff] = gp_trvar(gp, x);  % f x 1  vector
              K_fu = gp_cov(gp, x, u);           % f x u
              K_uu = gp_trcov(gp, u);     % u x u, noiseles covariance K_uu
              K_uu = (K_uu+K_uu')./2;     % ensure the symmetry of K_uu
              [Luu, notpositivedefinite] = chol(K_uu, 'lower');
              if notpositivedefinite
                [e, edata, eprior, tautilde, nutilde, L, La2, b, muvec_i, sigm2vec_i, Z_i, eta, ch] = set_output_for_notpositivedefinite();
                return
              end
              % Evaluate the Lambda (La)
              % Q_ff = K_fu*inv(K_uu)*K_fu'
              % Here we need only the diag(Q_ff), which is evaluated below
              B=Luu\(K_fu');       % u x f
              Qv_ff=sum(B.^2)';
              Lav = Cv_ff-Qv_ff;   % f x 1, Vector of diagonal elements
              % iLaKfu = diag(iLav)*K_fu = inv(La)*K_fu
              % First some helper parameters
              iLaKfu = zeros(size(K_fu));  % f x u,
              for i=1:n
                iLaKfu(i,:) = K_fu(i,:)./Lav(i);  % f x u
              end
              A = K_uu+K_fu'*iLaKfu;  A = (A+A')./2;     % Ensure symmetry
              [A, notpositivedefinite] = chol(A);
              if notpositivedefinite
                [e, edata, eprior, tautilde, nutilde, L, La2, b, muvec_i, sigm2vec_i, Z_i, eta, ch] = set_output_for_notpositivedefinite();
                return
              end
              L = iLaKfu/A;
              Lahat = 1./Lav;
              I = eye(size(K_uu));
              
              [R0, notpositivedefinite] = chol(inv(K_uu));
              if notpositivedefinite
                [e, edata, eprior, tautilde, nutilde, L, La2, b, muvec_i, sigm2vec_i, Z_i, eta, ch] = set_output_for_notpositivedefinite();
                return
              end
              R = R0;
              P = K_fu;
              myy = zeros(size(y));
              eta = zeros(size(y));
              gamma = zeros(size(K_uu,1),1);
              D_vec = Lav;
              Ann=0;
              
              while iter<=maxiter && abs(logZep_tmp-logZep)>tol
                
                logZep_tmp=logZep;
                muvec_i = zeros(n,1); sigm2vec_i = zeros(n,1);
                for i1=1:n
                  % approximate cavity parameters
                  pn = P(i1,:)';
                  Ann = D_vec(i1) + sum((R*pn).^2);
                  tau_i = Ann^-1-tautilde(i1);
                  myy(i1) = eta(i1) + pn'*gamma;
                  vee_i = Ann^-1*myy(i1)-nutilde(i1);
                  
                  myy_i=vee_i/tau_i;
                  sigm2_i=tau_i^-1;
                  
                  % marginal moments
                  [M0(i1), muhati, sigm2hati] = gp.lik.fh.tiltedMoments(gp.lik, y, i1, sigm2_i, myy_i, z);
                  
                  % update site parameters
                  deltatautilde = sigm2hati^-1-tau_i-tautilde(i1);
                  tautilde(i1) = tautilde(i1)+deltatautilde;
                  deltanutilde = sigm2hati^-1*muhati-vee_i - nutilde(i1);
                  nutilde(i1) = sigm2hati^-1*muhati-vee_i;
                  
                  % Standard EP
                  if isequal(gp.latent_opt.parallel,'off')
                    % Update the parameters
                    dn = D_vec(i1);
                    D_vec(i1) = D_vec(i1) - deltatautilde.*D_vec(i1).^2 ./ (1+deltatautilde.*D_vec(i1));
                    P(i1,:) = pn' - (deltatautilde.*dn ./ (1+deltatautilde.*dn)).*pn';
                    updfact = deltatautilde./(1 + deltatautilde.*Ann);
                    if updfact > 0
                      RtRpnU = R'*(R*pn).*sqrt(updfact);
                      R = cholupdate(R, RtRpnU, '-');
                    elseif updfact < 0
                      RtRpnU = R'*(R*pn).*sqrt(abs(updfact));
                      R = cholupdate(R, RtRpnU, '+');
                    end
                    eta(i1) = eta(i1) + (deltanutilde - deltatautilde.*eta(i1)).*dn./(1+deltatautilde.*dn);
                    gamma = gamma + (deltanutilde - deltatautilde.*myy(i1))./(1+deltatautilde.*dn) * R'*(R*pn);
                    %                            myy = eta + P*gamma;
                  else
                    % Parallel EP
                  end
                  
                  % Store cavity parameters
                  muvec_i(i1,1)=myy_i;
                  sigm2vec_i(i1,1)=sigm2_i;
                end
                
                
                % Re-evaluate the parameters
                temp1 = (1+Lav.*tautilde).^(-1);
                D_vec = temp1.*Lav;
                R0P0t = R0*K_fu';
                temp2 = zeros(size(R0P0t));
                for i2 = 1:length(temp1)
                  P(i2,:) = temp1(i2).*K_fu(i2,:);
                  temp2(:,i2) = R0P0t(:,i2).*tautilde(i2).*temp1(i2);
                end
                R = chol(inv(eye(size(R0)) + temp2*R0P0t')) * R0;
                eta = D_vec.*nutilde;
                gamma = R'*(R*(P'*nutilde));
                myy = eta + P*gamma;
                
                % Compute the marginal likelihood, see FULL model for
                % details about equations
                Lahat = 1./Lav + tautilde;
                Lhat = bsxfun(@rdivide,L,Lahat);
                H = I-L'*Lhat;
                B = H\L';
                Bhat = B./repmat(Lahat',m,1);
                
                % 4. term & 1. term
                Stildesqroot=sqrt(tautilde);
                D = Stildesqroot.*Lav.*Stildesqroot + 1;
                SsqrtKfu = K_fu.*repmat(Stildesqroot,1,m);
                AA = K_uu + (SsqrtKfu'./repmat(D',m,1))*SsqrtKfu; AA = (AA+AA')/2;
                [AA, notpositivedefinite] = chol(AA,'lower');
                if notpositivedefinite
                  [e, edata, eprior, tautilde, nutilde, L, La2, b, muvec_i, sigm2vec_i, Z_i, eta, ch] = set_output_for_notpositivedefinite();
                  return
                end
                term41 = - 0.5*sum(log(1+tautilde.*sigm2vec_i)) - sum(log(diag(Luu))) + sum(log(diag(AA))) + 0.5.*sum(log(D));
                
                % 5. term (1/2 element) & 2. term
                T=1./sigm2vec_i;
                term52 = -0.5*( (nutilde./Lahat)'*nutilde + (nutilde'*Lhat)*(Bhat*nutilde) - (nutilde./(T+tautilde))'*nutilde);
                
                % 5. term (2/2 element)
                term5 = - 0.5*muvec_i'.*(T./(tautilde+T))'*(tautilde.*muvec_i-2*nutilde);
                
                % 3. term
                term3 = -sum(log(M0));
                
                logZep = term41+term52+term5+term3;
                
                iter=iter+1;
              end
              edata = logZep;
              %L = iLaKfu;
              
              % b'  = (La + Kfu*iKuu*Kuf + 1./S)*1./S * nutilde
              %     = (S - S * (iLa - L*L' + S)^(-1) * S) * 1./S
              %     = I - S * (Lahat - L*L')^(-1)
              % L   = S*Kfu * (Lav + 1./S)^(-1) / chol(K_uu + SsqrtKfu'*(Lav + 1./S)^(-1)*SsqrtKfu)
              % La2 = D./S = Lav + 1./S,
              %
              % The way evaluations are done is numerically more stable
              % See equations (3.71) and (3.72) in Rasmussen and Williams (2006)
              b = nutilde'.*(1 - Stildesqroot./Lahat.*Stildesqroot)' - (nutilde'*Lhat)*Bhat.*tautilde';    % part of eq. (3.71)
              L = ((repmat(Stildesqroot,1,m).*SsqrtKfu)./repmat(D',m,1)')/AA';                             % part of eq. (3.72)
              La2 = 1./(Stildesqroot./D.*Stildesqroot);                                                    % part of eq. (3.72)
              D = D_vec;
              
              % ============================================================
              % PIC
              % ============================================================
            case {'PIC' 'PIC_BLOCK'}
              ind = gp.tr_index;
              u = gp.X_u;
              m = length(u);
              
              % First evaluate needed covariance matrices
              % v defines that parameter is a vector
              K_fu = gp_cov(gp, x, u);         % f x u
              
              K_uu = gp_trcov(gp, u);    % u x u, noiseles covariance K_uu
              K_uu = (K_uu+K_uu')./2;     % ensure the symmetry of K_uu
              [Luu, notpositivedefinite] = chol(K_uu, 'lower');
              if notpositivedefinite
                [e, edata, eprior, tautilde, nutilde, L, La2, b, muvec_i, sigm2vec_i, Z_i, eta, ch] = set_output_for_notpositivedefinite();
                return
              end
              % Evaluate the Lambda (La)
              % Q_ff = K_fu*inv(K_uu)*K_fu'
              % Here we need only the diag(Q_ff), which is evaluated below
              B=Luu\(K_fu');       % u x f
              
              % First some helper parameters
              iLaKfu = zeros(size(K_fu));  % f x u
              for i=1:length(ind)
                Qbl_ff = B(:,ind{i})'*B(:,ind{i});
                [Kbl_ff, Cbl_ff] = gp_trcov(gp, x(ind{i},:));
                Labl{i} = Cbl_ff - Qbl_ff;
                [Llabl, notpositivedefinite] = chol(Labl{i});
                if notpositivedefinite
                  [e, edata, eprior, tautilde, nutilde, L, La2, b, muvec_i, sigm2vec_i, Z_i, eta, ch] = set_output_for_notpositivedefinite();
                  return
                end
                iLaKfu(ind{i},:) = Llabl\(Llabl'\K_fu(ind{i},:));
              end
              A = K_uu+K_fu'*iLaKfu;
              A = (A+A')./2;     % Ensure symmetry
              [A, notpositivedefinite] = chol(A);
              if notpositivedefinite
                [e, edata, eprior, tautilde, nutilde, L, La2, b, muvec_i, sigm2vec_i, Z_i, eta, ch] = set_output_for_notpositivedefinite();
                return
              end
              L = iLaKfu/A;
              I = eye(size(K_uu));
              
              [R0, notpositivedefinite] = chol(inv(K_uu));
              if notpositivedefinite
                [e, edata, eprior, tautilde, nutilde, L, La2, b, muvec_i, sigm2vec_i, Z_i, eta, ch] = set_output_for_notpositivedefinite();
                return
              end
              R = R0;
              P = K_fu;
              R0P0t = R0*K_fu';
              myy = zeros(size(y));
              eta = zeros(size(y));
              gamma = zeros(size(K_uu,1),1);
              D = Labl;
              Ann=0;
              
              while iter<=maxiter && abs(logZep_tmp-logZep)>tol
                
                logZep_tmp=logZep;
                muvec_i = zeros(n,1); sigm2vec_i = zeros(n,1);
                for bl=1:length(ind)
                  bl_ind = ind{bl};
                  for in=1:length(bl_ind)
                    i1 = bl_ind(in);
                    % approximate cavity parameters
                    Dbl = D{bl}; dn = Dbl(in,in); pn = P(i1,:)';
                    Ann = dn + sum((R*pn).^2);
                    tau_i = Ann^-1-tautilde(i1);
                    myy(i1) = eta(i1) + pn'*gamma;
                    vee_i = Ann^-1*myy(i1)-nutilde(i1);
                    
                    myy_i=vee_i/tau_i;
                    sigm2_i=tau_i^-1;
                    
                    % marginal moments
                    [M0(i1), muhati, sigm2hati] = gp.lik.fh.tiltedMoments(gp.lik, y, i1, sigm2_i, myy_i, z);
                    
                    % update site parameters
                    deltatautilde = sigm2hati^-1-tau_i-tautilde(i1);
                    tautilde(i1) = tautilde(i1)+deltatautilde;
                    deltanutilde = sigm2hati^-1*muhati-vee_i - nutilde(i1);
                    nutilde(i1) = sigm2hati^-1*muhati-vee_i;
                    
                    if isequal(gp.latent_opt.parallel,'off')
                      % Update the parameters
                      Dblin = Dbl(:,in);
                      Dbl = Dbl - deltatautilde ./ (1+deltatautilde.*dn) * Dblin*Dblin';
                      %Dbl = inv(inv(Dbl) + diag(tautilde(bl_ind)));
                      P(bl_ind,:) = P(bl_ind,:) - ((deltatautilde ./ (1+deltatautilde.*dn)).* Dblin)*pn';
                      updfact = deltatautilde./(1 + deltatautilde.*Ann);
                      if updfact > 0
                        RtRpnU = R'*(R*pn).*sqrt(updfact);
                        R = cholupdate(R, RtRpnU, '-');
                      elseif updfact < 0
                        RtRpnU = R'*(R*pn).*sqrt(abs(updfact));
                        R = cholupdate(R, RtRpnU, '+');
                      end
                      eta(bl_ind) = eta(bl_ind) + (deltanutilde - deltatautilde.*eta(i1))./(1+deltatautilde.*dn).*Dblin;
                      gamma = gamma + (deltanutilde - deltatautilde.*myy(i1))./(1+deltatautilde.*dn) * (R'*(R*pn));
                      %myy = eta + P*gamma;
                      
                      D{bl} = Dbl;
                    else
                      % Parallel EP
                    end
                    % Store cavity parameters
                    muvec_i(i1,1)=myy_i;
                    sigm2vec_i(i1,1)=sigm2_i;
                  end
                end
                % Re-evaluate the parameters
                temp2 = zeros(size(R0P0t));
                
                Stildesqroot=sqrt(tautilde);
                for i=1:length(ind)
                  sdtautilde = diag(Stildesqroot(ind{i}));
                  Dhat = sdtautilde*Labl{i}*sdtautilde + eye(size(Labl{i}));
                  [Ldhat{i}, notpositivedefinite] = chol(Dhat);
                  if notpositivedefinite
                    [e, edata, eprior, tautilde, nutilde, L, La2, b, muvec_i, sigm2vec_i, Z_i, eta, ch] = set_output_for_notpositivedefinite();
                    return
                  end
                  D{i} = Labl{i} - Labl{i}*sdtautilde*(Ldhat{i}\(Ldhat{i}'\sdtautilde*Labl{i}));
                  P(ind{i},:) = D{i}*(Labl{i}\K_fu(ind{i},:));
                  
                  temp2(:,ind{i}) = R0P0t(:,ind{i})*sdtautilde/Dhat*sdtautilde;
                  eta(ind{i}) = D{i}*nutilde(ind{i});
                end
                R = chol(inv(eye(size(R0)) + temp2*R0P0t')) * R0;
                gamma = R'*(R*(P'*nutilde));
                myy = eta + P*gamma;
                
                % Compute the marginal likelihood, see FULL model for
                % details about equations
                %
                % First some helper parameters
                for i = 1:length(ind)
                  Lhat(ind{i},:) = D{i}*L(ind{i},:);
                end
                H = I-L'*Lhat;
                B = H\L';
                
                % Compute the marginal likelihood, see FULL model for
                % details about equations
                term41 = 0; term52 = 0;
                for i=1:length(ind)
                  Bhat(:,ind{i}) = B(:,ind{i})*D{i};
                  SsqrtKfu(ind{i},:) = bsxfun(@times,K_fu(ind{i},:),Stildesqroot(ind{i}));
                  %SsqrtKfu(ind{i},:) = gtimes(K_fu(ind{i},:),Stildesqroot(ind{i}));
                  iDSsqrtKfu(ind{i},:) = Ldhat{i}\(Ldhat{i}'\SsqrtKfu(ind{i},:));
                  term41 = term41 + sum(log(diag(Ldhat{i})));
                  term52 = term52 + nutilde(ind{i})'*(D{i}*nutilde(ind{i}));
                  
                end
                AA = K_uu + SsqrtKfu'*iDSsqrtKfu; AA = (AA+AA')/2;
                [AA, notpositivedefinite] = chol(AA,'lower');
                if notpositivedefinite
                  [e, edata, eprior, tautilde, nutilde, L, La2, b, muvec_i, sigm2vec_i, Z_i, eta, ch] = set_output_for_notpositivedefinite();
                  return
                end
                term41 = term41 - 0.5*sum(log(1+tautilde.*sigm2vec_i)) - sum(log(diag(Luu))) + sum(log(diag(AA)));
                
                % 5. term (1/2 element) & 2. term
                T=1./sigm2vec_i;
                term52 = -0.5*( term52 + (nutilde'*Lhat)*(Bhat*nutilde) - (nutilde./(T+tautilde))'*nutilde);
                
                % 5. term (2/2 element)
                term5 = - 0.5*muvec_i'.*(T./(tautilde+T))'*(tautilde.*muvec_i-2*nutilde);
                
                % 3. term
                term3 = -sum(log(M0));
                
                logZep = term41+term52+term5+term3;
                
                iter=iter+1;
              end
              edata = logZep;
              
              b = zeros(1,n);
              for i=1:length(ind)
                b(ind{i}) = nutilde(ind{i})'*D{i};
                La2{i} = inv(diag(Stildesqroot(ind{i}))*(Ldhat{i}\(Ldhat{i}'\diag(Stildesqroot(ind{i})))));
              end
              b = nutilde' - ((b + (nutilde'*Lhat)*Bhat).*tautilde');
              
              L = (repmat(Stildesqroot,1,m).*iDSsqrtKfu)/AA';
              
              % ============================================================
              % CS+FIC
              % ============================================================
            case 'CS+FIC'
              u = gp.X_u;
              m = length(u);
              cf_orig = gp.cf;
              
              cf1 = {};
              cf2 = {};
              j = 1;
              k = 1;
              for i = 1:ncf
                if ~isfield(gp.cf{i},'cs')
                  cf1{j} = gp.cf{i};
                  j = j + 1;
                else
                  cf2{k} = gp.cf{i};
                  k = k + 1;
                end
              end
              gp.cf = cf1;
              
              % First evaluate needed covariance matrices
              % v defines that parameter is a vector
              [Kv_ff, Cv_ff] = gp_trvar(gp, x);  % f x 1  vector
              K_fu = gp_cov(gp, x, u);           % f x u
              K_uu = gp_trcov(gp, u);            % u x u, noiseles covariance K_uu
              K_uu = (K_uu+K_uu')./2;            % ensure the symmetry of K_uu
              [Luu, notpositivedefinite] = chol(K_uu, 'lower');
              if notpositivedefinite
                [e, edata, eprior, tautilde, nutilde, L, La2, b, muvec_i, sigm2vec_i, Z_i, eta, ch] = set_output_for_notpositivedefinite();
                return
              end
              
              % Evaluate the Lambda (La)
              % Q_ff = K_fu*inv(K_uu)*K_fu'
              B=Luu\(K_fu');       % u x f
              Qv_ff=sum(B.^2)';
              Lav = Cv_ff-Qv_ff;   % f x 1, Vector of diagonal elements
              
              gp.cf = cf2;
              K_cs = gp_trcov(gp,x);
              La = sparse(1:n,1:n,Lav,n,n) + K_cs;
              gp.cf = cf_orig;
              
              % clear unnecessary variables
              clear K_cs; clear Qv_ff; clear Kv_ff; clear Cv_ff; clear Lav;
              
              % Find fill reducing permutation and permute all the
              % matrices
              p = analyze(La);
              r(p) = 1:n;
              if ~isempty(z)
                z = z(p,:);
              end
              y = y(p);
              La = La(p,p);
              K_fu = K_fu(p,:);
              
              [VD, notpositivedefinite] = ldlchol(La);
              if notpositivedefinite
                [e, edata, eprior, tautilde, nutilde, L, La2, b, muvec_i, sigm2vec_i, Z_i, eta, ch] = set_output_for_notpositivedefinite();
                return
              end
              iLaKfu = ldlsolve(VD,K_fu);
              A = K_uu+K_fu'*iLaKfu; A = (A+A')./2;     % Ensure symmetry
              [A, notpositivedefinite] = chol(A);
              if notpositivedefinite
                [e, edata, eprior, tautilde, nutilde, L, La2, b, muvec_i, sigm2vec_i, Z_i, eta, ch] = set_output_for_notpositivedefinite();
                return
              end
              L = iLaKfu/A;
              
              I = eye(size(K_uu));
              
              Inn = sparse(1:n,1:n,1,n,n);
              sqrtS = sparse(1:n,1:n,0,n,n);
              [R0, notpositivedefinite] = chol(inv(K_uu));
              if notpositivedefinite
                [e, edata, eprior, tautilde, nutilde, L, La2, b, muvec_i, sigm2vec_i, Z_i, eta, ch] = set_output_for_notpositivedefinite();
                return
              end
              R = R0;
              P = K_fu;
              R0P0t = R0*K_fu';
              myy = zeros(size(y));
              eta = zeros(size(y));
              gamma = zeros(size(K_uu,1),1);
              Ann=0;
              LasqrtS = La*sqrtS;
              [VD, notpositivedefinite] = ldlchol(Inn);
              if notpositivedefinite
                [e, edata, eprior, tautilde, nutilde, L, La2, b, muvec_i, sigm2vec_i, Z_i, eta, ch] = set_output_for_notpositivedefinite();
                return
              end
              while iter<=maxiter && abs(logZep_tmp-logZep)>tol
                
                logZep_tmp=logZep;
                muvec_i = zeros(n,1); sigm2vec_i = zeros(n,1);
                for i1=1:n
                  % approximate cavity parameters
                  tttt = ldlsolve(VD,ssmult(sqrtS,La(:,i1)));
                  Di1 =  La(:,i1) - ssmult(LasqrtS,tttt);
                  
                  dn = Di1(i1);
                  pn = P(i1,:)';
                  Ann = dn + sum((R*pn).^2);
                  tau_i = Ann^-1-tautilde(i1);
                  myy(i1) = eta(i1) + pn'*gamma;
                  vee_i = Ann^-1*myy(i1)-nutilde(i1);
                  
                  myy_i=vee_i/tau_i;
                  sigm2_i= tau_i^-1;  % 1./tau_i;  %
                  
                  % marginal moments
                  [M0(i1), muhati, sigm2hati] = gp.lik.fh.tiltedMoments(gp.lik, y, i1, sigm2_i, myy_i, z);
                  
                  % update site parameters
                  deltatautilde = sigm2hati^-1-tau_i-tautilde(i1);
                  tautilde(i1) = tautilde(i1)+deltatautilde;
                  deltanutilde = sigm2hati^-1*muhati-vee_i - nutilde(i1);
                  nutilde(i1) = sigm2hati^-1*muhati-vee_i;
                  
                  % Standard EP
                  if isequal(gp.latent_opt.parallel,'off')
                    % Update the parameters
                    P = P - ((deltatautilde ./ (1+deltatautilde.*dn)).* Di1)*pn';
                    updfact = deltatautilde./(1 + deltatautilde.*Ann);
                    if updfact > 0
                      RtRpnU = R'*(R*pn).*sqrt(updfact);
                      R = cholupdate(R, RtRpnU, '-');
                    elseif updfact < 0
                      RtRpnU = R'*(R*pn).*sqrt(abs(updfact));
                      R = cholupdate(R, RtRpnU, '+');
                    end
                    eta = eta + (deltanutilde - deltatautilde.*eta(i1))./(1+deltatautilde.*dn).*Di1;
                    gamma = gamma + (deltanutilde - deltatautilde.*myy(i1))./(1+deltatautilde.*dn) * (R'*(R*pn));
                    
                    % Store cavity parameters
                    muvec_i(i1,1)=myy_i;
                    sigm2vec_i(i1,1)=sigm2_i;
                    
                    D2_o = ssmult(sqrtS,LasqrtS(:,i1)) + Inn(:,i1);
                    sqrtS(i1,i1) = sqrt(tautilde(i1));
                    LasqrtS(:,i1) = La(:,i1).*sqrtS(i1,i1);
                    D2_n = ssmult(sqrtS,LasqrtS(:,i1)) + Inn(:,i1);
                    
                    if tautilde(i1) - deltatautilde == 0
                      VD = ldlrowupdate(i1,VD,VD(:,i1),'-');
                      VD = ldlrowupdate(i1,VD,D2_n,'+');
                    else
                      VD = ldlrowmodify(VD, D2_n, i1);
                    end
                  else
                    % Parallel EP
                    error('This is not implemented yet')
                  end
                  
                  
                end
                % Re-evaluate the parameters
                sqrtS = sparse(1:n,1:n,sqrt(tautilde),n,n);
                sqrtSLa = ssmult(sqrtS,La);
                D2 = ssmult(sqrtSLa,sqrtS) + Inn;
                LasqrtS = ssmult(La,sqrtS);
                [VD, notpositivedefinite] = ldlchol(D2);
                if notpositivedefinite
                  [e, edata, eprior, tautilde, nutilde, L, La2, b, muvec_i, sigm2vec_i, Z_i, eta, ch] = set_output_for_notpositivedefinite();
                  return
                end
                
                SsqrtKfu = sqrtS*K_fu;
                iDSsqrtKfu = ldlsolve(VD,SsqrtKfu);
                P = K_fu - sqrtSLa'*iDSsqrtKfu;
                R = chol(inv( eye(size(R0)) + R0P0t*sqrtS*ldlsolve(VD,sqrtS*R0P0t'))) * R0;
                eta = La*nutilde - sqrtSLa'*ldlsolve(VD,sqrtSLa*nutilde);
                gamma = R'*(R*(P'*nutilde));
                myy = eta + P*gamma;
                
                % Compute the marginal likelihood,
                Lhat = La*L - sqrtSLa'*ldlsolve(VD,sqrtSLa*L);
                H = I-L'*Lhat;
                B = H\L';
                Bhat = B*La - ldlsolve(VD,sqrtSLa*B')'*sqrtSLa;
                
                % 4. term & 1. term
                AA = K_uu + SsqrtKfu'*iDSsqrtKfu; AA = (AA+AA')/2;
                [AA, notpositivedefinite] = chol(AA,'lower');
                if notpositivedefinite
                  [e, edata, eprior, tautilde, nutilde, L, La2, b, muvec_i, sigm2vec_i, Z_i, eta, ch] = set_output_for_notpositivedefinite();
                  return
                end
                term41 = - 0.5*sum(log(1+tautilde.*sigm2vec_i)) - sum(log(diag(Luu))) + sum(log(diag(AA))) + 0.5*sum(log(diag(VD)));
                
                % 5. term (1/2 element) & 2. term
                T=1./sigm2vec_i;
                term52 = -0.5*( nutilde'*(eta) + (nutilde'*Lhat)*(Bhat*nutilde) - (nutilde./(T+tautilde))'*nutilde);
                
                % 5. term (2/2 element)
                term5 = - 0.5*muvec_i'.*(T./(tautilde+T))'*(tautilde.*muvec_i-2*nutilde);
                
                % 3. term
                term3 = -sum(log(M0));
                
                logZep = term41+term52+term5+term3;
                
                iter=iter+1;
              end
              edata = logZep;
              
              % b'  = (K_fu/K_uu*K_fu' + La + diag(1./tautilde)) \ (tautilde.\nutilde)
              % L   = S*Kfu * (Lav + 1./S)^(-1) / chol(K_uu + SsqrtKfu'*(Lav + 1./S)^(-1)*SsqrtKfu)
              % La2 = D./S = Lav + 1./S,
              %
              % The way evaluations are done is numerically more stable than with inversion of S (tautilde)
              % See equations (3.71) and (3.72) in Rasmussen and Williams (2006)
              b = nutilde' - ((eta' + (nutilde'*Lhat)*Bhat).*tautilde');
              
              L = (sqrtS*iDSsqrtKfu)/AA';
              La2 = sqrtS\D2/sqrtS;
              
              % Reorder all the returned and stored values
              b = b(r);
              L = L(r,:);
              La2 = La2(r,r);
              D = La(r,r);
              nutilde = nutilde(r);
              tautilde = tautilde(r);
              myy = myy(r);
              P = P(r,:);
              y = y(r);
              if ~isempty(z)
                z = z(r,:);
              end
              % ============================================================
              % DTC,VAR
              % ============================================================
            case {'DTC' 'VAR' 'SOR'}
              % First evaluate needed covariance matrices
              % v defines that parameter is a vector
              u = gp.X_u;
              m = size(u,1);
              
              % First evaluate needed covariance matrices
              % v defines that parameter is a vector
              [Kv_ff, Cv_ff] = gp_trvar(gp, x);  % f x 1  vector
              K_fu = gp_cov(gp, x, u);           % f x u
              K_uu = gp_trcov(gp, u);     % u x u, noiseles covariance K_uu
              K_uu = (K_uu+K_uu')./2;     % ensure the symmetry of K_uu
              [Luu, notpositivedefinite] = chol(K_uu, 'lower');
              if notpositivedefinite
                [e, edata, eprior, tautilde, nutilde, L, La2, b, muvec_i, sigm2vec_i, Z_i, eta, ch] = set_output_for_notpositivedefinite();
                return
              end
              % Evaluate the Lambda (La)
              % Q_ff = K_fu*inv(K_uu)*K_fu'
              % Here we need only the diag(Q_ff), which is evaluated below
              B=Luu\(K_fu');       % u x f
              
              
              Phi = B';
              m = size(Phi,2);
              
              R = eye(m,m);
              P = Phi;
              myy = zeros(size(y));
              gamma = zeros(m,1);
              Ann=0;
              
              while iter<=maxiter && abs(logZep_tmp-logZep)>tol
                
                logZep_tmp=logZep;
                muvec_i = zeros(n,1); sigm2vec_i = zeros(n,1);
                for i1=1:n
                  % approximate cavity parameters
                  phi = Phi(i1,:)';
                  Ann = sum((R*phi).^2);
                  tau_i = Ann^-1-tautilde(i1);
                  myy(i1) = phi'*gamma;
                  vee_i = Ann^-1*myy(i1)-nutilde(i1);
                  
                  myy_i=vee_i/tau_i;
                  sigm2_i=tau_i^-1;
                  
                  % marginal moments
                  [M0(i1), muhati, sigm2hati] = gp.lik.fh.tiltedMoments(gp.lik, y, i1, sigm2_i, myy_i, z);
                  
                  % update site parameters
                  deltatautilde = sigm2hati^-1-tau_i-tautilde(i1);
                  tautilde(i1) = tautilde(i1)+deltatautilde;
                  deltanutilde = sigm2hati^-1*muhati-vee_i - nutilde(i1);
                  nutilde(i1) = sigm2hati^-1*muhati-vee_i;
                  
                  % Standard EP
                  if isequal(gp.latent_opt.parallel,'off')
                    % Update the parameters
                    lnn = sum((R*phi).^2);
                    updfact = deltatautilde/(1 + deltatautilde*lnn);
                    if updfact > 0
                      RtLphiU = R'*(R*phi).*sqrt(updfact);
                      R = cholupdate(R, RtLphiU, '-');
                    elseif updfact < 0
                      RtLphiU = R'*(R*phi).*sqrt(updfact);
                      R = cholupdate(R, RtLphiU, '+');
                    end
                    gamma = gamma - R'*(R*phi)*(deltatautilde*myy(i1)-deltanutilde);
                  else
                    % Parallel EP
                  end
                  
                  % Store cavity parameters
                  muvec_i(i1,1)=myy_i;
                  sigm2vec_i(i1,1)=sigm2_i;
                end
                
                SS = Phi/(eye(m,m)+Phi'*diag(tautilde)*Phi)*Phi' ;
                
                % Re-evaluate the parameters
                R = chol(inv(eye(m,m) + Phi'*(repmat(tautilde,1,m).*Phi)));
                gamma = R'*(R*(Phi'*nutilde));
                myy = Phi*gamma;
                
                % Compute the marginal likelihood, see FULL model for
                % details about equations
                % 4. term & 1. term
                Stildesqroot=sqrt(tautilde);
                SsqrtPhi = Phi.*repmat(Stildesqroot,1,m);
                AA = eye(m,m) + SsqrtPhi'*SsqrtPhi; AA = (AA+AA')/2;
                [AA, notpositivedefinite] = chol(AA,'lower');
                if notpositivedefinite
                  [e, edata, eprior, tautilde, nutilde, L, La2, b, muvec_i, sigm2vec_i, Z_i, eta, ch] = set_output_for_notpositivedefinite();
                  return
                end
                term41 = - 0.5*sum(log(1+tautilde.*sigm2vec_i)) + sum(log(diag(AA)));
                
                % 5. term (1/2 element) & 2. term
                T=1./sigm2vec_i;
                bb = nutilde'*Phi;
                bb2 = bb*SsqrtPhi';
                bb3 = bb2*SsqrtPhi/AA';
                term52 = -0.5*( bb*bb' - bb2*bb2' + bb3*bb3' - (nutilde./(T+tautilde))'*nutilde);
                
                % 5. term (2/2 element)
                term5 = - 0.5*muvec_i'.*(T./(tautilde+T))'*(tautilde.*muvec_i-2*nutilde);
                
                % 3. term
                term3 = -sum(log(M0));
                
                logZep = term41+term52+term5+term3;
                
                iter=iter+1;
              end
              edata = logZep;
              %L = iLaKfu;
              if strcmp(gp.type,'VAR')
                Qv_ff = sum(B.^2)';
                edata = edata + 0.5*sum((Kv_ff-Qv_ff).*tautilde);
              end
              
              temp = Phi*(SsqrtPhi'*(SsqrtPhi*bb'));
              %                b = Phi*bb' - temp + Phi*(SsqrtPhi'*(SsqrtPhi*(AA'\(AA\temp))));
              
              b = nutilde - bb2'.*Stildesqroot + repmat(tautilde,1,m).*Phi*(AA'\bb3');
              b = b';
              
              %                 StildeKfu = zeros(size(K_fu));  % f x u,
              %                 for i=1:n
              %                     StildeKfu(i,:) = K_fu(i,:).*tautilde(i);  % f x u
              %                 end
              %                 A = K_uu+K_fu'*StildeKfu;  A = (A+A')./2;     % Ensure symmetry
              %                 A = chol(A);
              %                 L = StildeKfu/A;
              L = repmat(tautilde,1,m).*Phi/AA';
              %L = repmat(tautilde,1,m).*K_fu/AA';
              mu=nutilde./tautilde;
              %b = nutilde - mu'*L*L'*mu;
              %b=b';
              La2 = 1./tautilde;
              D = 0;
              
              % ============================================================
              % SSGP
              % ============================================================
            case 'SSGP'        % Predictions with sparse spectral sampling approximation for GP
              % The approximation is proposed by M. Lazaro-Gredilla, J. Quinonero-Candela and A. Figueiras-Vidal
              % in Microsoft Research technical report MSR-TR-2007-152 (November 2007)
              % NOTE! This does not work at the moment.
              
              % First evaluate needed covariance matrices
              % v defines that parameter is a vector
              Phi = gp_trcov(gp, x);        % n x m matrix and nxn sparse matrix
              m = size(Phi,2);
              
              R = eye(m,m);
              P = Phi;
              myy = zeros(size(y));
              gamma = zeros(m,1);
              Ann=0;
              
              while iter<=maxiter && abs(logZep_tmp-logZep)>tol
                
                logZep_tmp=logZep;
                muvec_i = zeros(n,1); sigm2vec_i = zeros(n,1);
                for i1=1:n
                  % approximate cavity parameters
                  phi = Phi(i1,:)';
                  Ann = sum((R*phi).^2);
                  tau_i = Ann^-1-tautilde(i1);
                  myy(i1) = phi'*gamma;
                  vee_i = Ann^-1*myy(i1)-nutilde(i1);
                  
                  myy_i=vee_i/tau_i;
                  sigm2_i=tau_i^-1;
                  
                  % marginal moments
                  [M0(i1), muhati, sigm2hati] = gp.lik.fh.tiltedMoments(gp.lik, y, i1, sigm2_i, myy_i, z);
                  
                  % update site parameters
                  deltatautilde = sigm2hati^-1-tau_i-tautilde(i1);
                  tautilde(i1) = tautilde(i1)+deltatautilde;
                  deltanutilde = sigm2hati^-1*muhati-vee_i - nutilde(i1);
                  nutilde(i1) = sigm2hati^-1*muhati-vee_i;
                  
                  % Update the parameters
                  lnn = sum((R*phi).^2);
                  updfact = deltatautilde/(1 + deltatautilde*lnn);
                  if updfact > 0
                    RtLphiU = R'*(R*phi).*sqrt(updfact);
                    R = cholupdate(R, RtLphiU, '-');
                  elseif updfact < 0
                    RtLphiU = R'*(R*phi).*sqrt(updfact);
                    R = cholupdate(R, RtLphiU, '+');
                  end
                  gamma = gamma - R'*(R*phi)*(deltatautilde*myy(i1)-deltanutilde);
                  
                  % Store cavity parameters
                  muvec_i(i1,1)=myy_i;
                  sigm2vec_i(i1,1)=sigm2_i;
                end
                
                SS = Phi/(eye(m,m)+Phi'*diag(tautilde)*Phi)*Phi' ;
                
                % Re-evaluate the parameters
                R = chol(inv(eye(m,m) + Phi'*(repmat(tautilde,1,m).*Phi)));
                gamma = R'*(R*(Phi'*nutilde));
                myy = Phi*gamma;
                
                % Compute the marginal likelihood, see FULL model for
                % details about equations
                % 4. term & 1. term
                Stildesqroot=sqrt(tautilde);
                SsqrtPhi = Phi.*repmat(Stildesqroot,1,m);
                AA = eye(m,m) + SsqrtPhi'*SsqrtPhi; AA = (AA+AA')/2;
                [AA, notpositivedefinite] = chol(AA,'lower');
                if notpositivedefinite
                  [e, edata, eprior, tautilde, nutilde, L, La2, b, muvec_i, sigm2vec_i, Z_i, eta, ch] = set_output_for_notpositivedefinite();
                  return
                end
                term41 = - 0.5*sum(log(1+tautilde.*sigm2vec_i)) + sum(log(diag(AA)));
                
                % 5. term (1/2 element) & 2. term
                T=1./sigm2vec_i;
                bb = nutilde'*Phi;
                bb2 = bb*SsqrtPhi';
                bb3 = bb2*SsqrtPhi/AA';
                term52 = -0.5*( bb*bb' - bb2*bb2' + bb3*bb3' - (nutilde./(T+tautilde))'*nutilde);
                
                % 5. term (2/2 element)
                term5 = - 0.5*muvec_i'.*(T./(tautilde+T))'*(tautilde.*muvec_i-2*nutilde);
                
                % 3. term
                term3 = -sum(log(M0));
                
                logZep = term41+term52+term5+term3;
                
                iter=iter+1;
              end
              edata = logZep;
              %L = iLaKfu;
              
              temp = Phi*(SsqrtPhi'*(SsqrtPhi*bb'));
              %b = Phi*bb' - temp + Phi*(SsqrtPhi'*(SsqrtPhi*(AA'\(AA\temp))));
              
              b = nutilde - bb2'.*Stildesqroot + repmat(tautilde,1,m).*Phi*(AA'\bb3');
              b = b';
              
              L = repmat(tautilde,1,m).*Phi/AA';
              La2 = tautilde;
              D = 0;
            otherwise
              error('Unknown type of Gaussian process!')
          end
          
          % ==================================================
          % Evaluate the prior contribution to the error from
          % covariance functions and likelihood
          % ==================================================
          
          % Evaluate the prior contribution to the error from covariance
          % functions
          eprior = 0;
          for i=1:ncf
            gpcf = gp.cf{i};
            eprior = eprior - gpcf.fh.lp(gpcf);
          end
          
          % Evaluate the prior contribution to the error from likelihood
          % functions
          if isfield(gp.lik, 'p')
            lik = gp.lik;
            eprior = eprior - lik.fh.lp(lik);
          end
          
          % The last things to do
          if isfield(gp.latent_opt, 'display') && gp.latent_opt.display
            fprintf('   Number of iterations in EP: %d \n', iter-1)
          end
          
          e = edata + eprior;
          Z_i = M0(:);
          eta = [];
          
          % store values to the cache
          ch.w = w;
          ch.e = e;
          ch.edata = edata;
          ch.eprior = eprior;
          ch.tautilde = tautilde;
          ch.nutilde = nutilde;
          ch.L = L;
          ch.La2 = La2;
          ch.b = b;
          ch.muvec_i = muvec_i;
          ch.sigm2vec_i = sigm2vec_i;
          ch.Z_i = Z_i;
          ch.eta = eta;
          ch.datahash=datahash;
          
          global iter_lkm
          iter_lkm=iter;
        end
        
      case 'robust-EP'
        
        %   function [e,edata,eprior,tau_q,nu_q,L, La2, b, muvec_i,sigm2vec_i,Z_i, eta] = ep_algorithm2(w,gp,x,y,z)
        %
        %     if strcmp(w, 'clearcache')
        %       ch=[];
        %       return
        %     end
        
        % check whether saved values can be used
        if isempty(z)
          datahash=hash_sha512([x y]);
        else
          datahash=hash_sha512([x y z]);
        end
        
        if ~isempty(ch) && all(size(w)==size(ch.w)) && all(abs(w-ch.w) < 1e-8) && isequal(datahash,ch.datahash)
          % The covariance function parameters haven't changed so just
          % return the Energy and the site parameters that are saved
          
          e = ch.e;
          edata = ch.edata;
          eprior = ch.eprior;
          %       mf = ch.mf;
          L = ch.L;
          La2 = ch.La2;
          b = ch.b;
          nutilde = ch.nu_q;
          tautilde = ch.tau_q;
          eta = ch.eta;
          muvec_i = ch.muvec_i;
          sigm2vec_i = ch.sigm2vec_i;
          Z_i = ch.Z_i;
          %       nu_s = ch.nu_s;
          %       tau_s = ch.tau_s;
          %       maxds = ch.maxds;
          
        else
          % preparations
          maxiter=gp.latent_opt.maxiter;
          tolStop=gp.latent_opt.tolStop;
          tolUpdate=gp.latent_opt.tolUpdate;
          tolInner=gp.latent_opt.tolInner;
          tolGrad=gp.latent_opt.tolGrad;
          tauc_lim=gp.latent_opt.tauc_lim; % cavity precision limit
          ninit=gp.latent_opt.ninit;
          max_ninner=gp.latent_opt.max_ninner;
          
          % The parameters or data have changed since
          % the last call for gpep_e. In this case we need to
          % re-evaluate the EP approximation
          
          gp=gp_unpak(gp,w);
          likelih=gp.lik;
          ncf = length(gp.cf);
          n=length(y);
          
          df0=gp.latent_opt.df;
          eta=repmat(gp.latent_opt.eta,n,1);
          fh_tm=@(si,m_c,V_c,eta) likelih.fh.tiltedMoments2(likelih,y,si,V_c,m_c,z,eta);
          
          fprintf('\n')
          %       if likelih.fix_nu==0
          fprintf('Theta:%s ',sprintf(' %.2g,',exp([0.5*w(1) (w(2:end-2)) 0.5*w(end-1) exp(w(end))])))
          %       elseif
          %         fprintf('Theta:%s ',sprintf(' %.2g,',exp([0.5*w(1) (w(2:end-1)) 0.5*w(end)])))
          %       end
          fprintf('\n')
          
          % prior covariance
          K = gp_trcov(gp, x);
          
          % prior (zero) initialization
          [nu_q,tau_q]=deal(zeros(n,1));
          
          % initialize q-distribution
          [mf,Sf,lnZ_q]=evaluate_q(nu_q,tau_q,K);
          
          % surrogate distribution
          nu_s=mf./diag(Sf);
          tau_s=1./diag(Sf);
          lnZ_s=0.5*sum( (-log(tau_s) +nu_s.^2 ./tau_s)./eta ); % minus 0.5*log(2*pi)./eta
          
          % initialize r-distribution
          [lnZ_i,Z_i,m_r,V_r]=evaluate_r(nu_q,tau_q,eta,fh_tm,nu_s,tau_s);
          
          % initial energy (lnZ_ep)
          e = lnZ_q + lnZ_i -lnZ_s;
          fprintf('Initial energy: e=%.4f\n',e)
          
          % EP search direction (moment matching)
          up_mode='ep';
          [dnu_q,dtau_q]=ep_update_dir(mf,Sf,m_r,V_r,eta,up_mode,tolUpdate);
          
          %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
          % initialize with ninit rounds of parallel EP
          %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
          
          tauc_min=1./(tauc_lim*diag(K));
          df=df0;
          convergence=0;
          i1=0;
          maxds=zeros(1,2);
          while i1<ninit %|| ~cpos
            i1=i1+1;
            
            % damped update
            Vf_mult=2;
            
            dfi=df(ones(n,1));
            temp=(1/Vf_mult-1)./diag(Sf);
            ii2=df*dtau_q<temp;
            if any(ii2)
              dfi(ii2)=temp(ii2)./dtau_q(ii2);
            end
            
            nu_q2=nu_q+dfi.*dnu_q;
            tau_q2=tau_q+dfi.*dtau_q;
            
            % update q-distribution
            [mf2,Sf2,lnZ_q2,L1,L2]=evaluate_q(nu_q2,tau_q2,K);
            
            tau_s2=1./diag(Sf2);
            cpos=all( (tau_s2-eta.*tau_q2 )>=tauc_min);
            if isempty(L2) || ~cpos
              df=df*0.5;
              if df<0.1, break; end
              fprintf('%d, e=%.6f, dm=%.4f, dV=%.4f, increasing damping to df=%g.\n',i1,e,maxds(1),maxds(2),df)
            else
              [nu_q,tau_q,mf,Sf,lnZ_q]=deal(nu_q2,tau_q2,mf2,Sf2,lnZ_q2);
              
              % surrogate distribution
              nu_s=mf./diag(Sf);
              tau_s=tau_s2;
              lnZ_s=0.5*sum( (-log(tau_s) +nu_s.^2 ./tau_s)./eta );
              %cpos=all( (tau_s-eta.*tau_q )>=tauc_min);
              
              % r-distribution
              [lnZ_i,Z_i,m_r,V_r]=evaluate_r(nu_q,tau_q,eta,fh_tm,nu_s,tau_s);
              
              % EP search direction (moment matching)
              [dnu_q,dtau_q]=ep_update_dir(mf,Sf,m_r,V_r,eta,up_mode,tolUpdate);
              maxds=[max(abs(mf-m_r)) max(abs(diag(Sf)-V_r))];
              
              % EP energy
              e2 = lnZ_q + lnZ_i -lnZ_s;
              tol_e=abs(e2-e);
              e=e2;
              
              fprintf('%d, e=%.6f, dm=%.4f, dV=%.4f, df=%g.\n',i1,e,maxds(1),maxds(2),df)
              
              % Check for convergence
              if max(maxds)<tolStop
                convergence=1;
                break
              end
            end
          end
          
          if convergence==0
            %%%%%%%%%%%%%%%%%%%%%%%%%%%
            % start verified iterations
            %%%%%%%%%%%%%%%%%%%%%%%%%%%
            
            tol_e=inf;      % energy difference for measuring convergence (tol_e < tolStop)
            tol_ec=inf;
            ninner=0;
            
            % measure of expectation consistency
            fh_ec=@(mf,Vf,m_r,V_r) max(max(abs(Vf-V_r)),max(abs(mf-m_r)));
            
            ec = fh_ec(mf,diag(Sf),m_r,V_r);
            
            % continue with moment matching
            df=df0;     % initial step size (damping factor)
            df_lim=1;
            
            
            % intial gradient in the search direction
            g = sum( (mf -m_r).*dnu_q ) +0.5*sum( (V_r +m_r.^2 -diag(Sf) -mf.^2).*dtau_q );
            rec_sadj=[0 e g]; % record for step size adjustment
            for i1=1:maxiter
              
              %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
              % calculate new proposal state
              %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
              
              
              ii1=dtau_q>0;
              %df1=min( ( (1-tauc_lim)*tau_s(ii1)./eta(ii1)-tau_q(ii1) )./dtau_q(ii1)/df ,1);
              df1=min( ( (tau_s(ii1)-tauc_min(ii1))./eta(ii1)-tau_q(ii1) )./dtau_q(ii1)/df ,1);
              dnu_q(ii1)=dnu_q(ii1).*df1;
              dtau_q(ii1)=dtau_q(ii1).*df1;
              
              dfi=df;
              if any(df1<1)
                df_con=1;
              else
                df_con=0;
              end
              
              % proposal
              nu_q2=nu_q+dfi*dnu_q;
              tau_q2=tau_q+dfi*dtau_q;
              
              %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
              % objective for the proposal state
              %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
              
              % update q-distribution
              [mf2,Sf2,lnZ_q2,L1,L2]=evaluate_q(nu_q2,tau_q2,K);
              
              if isempty(L2)
                % q-distribution not defined
                e2=inf;
              else
                % tilted distribution
                [lnZ_i2,Z_i2,m_r2,V_r2]=evaluate_r(nu_q2,tau_q2,eta,fh_tm,nu_s,tau_s);
                
                % new energy
                e2 = lnZ_q2 + lnZ_i2 -lnZ_s;
                
                % new expectation consistency
                ec2 = fh_ec(mf2,diag(Sf2),m_r2,V_r2);
                
                % gradients in the search direction
                g2 = sum( (mf2 -m_r2).*dnu_q ) +0.5*sum( (V_r2 +m_r2.^2 -diag(Sf2) -mf2.^2).*dtau_q );
                
                fprintf('dg=%6.3f, ',abs(g2)/abs(g))
              end
              
              %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
              % check if the energy decreases
              %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
              if ~isfinite(e2) || g2>10*abs(g) %(df_con==1 && ec2>ec)
                %%%%%%%%%%%%%%%%%%%%
                % half the step size
                fprintf('decreasing df by 50%%, ')
                df=dfi*0.5;
                
              elseif size(rec_sadj,1)<=1 && ( e2>e || abs(g2)>abs(g)*tolGrad )
                
                %%%%%%%%%%%%%%%%%%%%%%%
                % no decrease in energy
                fprintf('adjusting step size,    ')
                
                % update the record
                ii1=find(dfi>rec_sadj(:,1),1,'last');
                ii2=find(dfi<rec_sadj(:,1),1,'first');
                rec_sadj=[rec_sadj(1:ii1,:); dfi e2 g2; rec_sadj(ii2:end,:)];
                
                if size(rec_sadj,1)>1
                  % adjust the step size with qubic interpolation
                  pp=csape(rec_sadj(:,1)',[rec_sadj(1,3) rec_sadj(:,2)' rec_sadj(end,3)],[1 1]);
                  if g2>0
                    [emax,df]=fnmin(pp,[0 dfi]);
                  else
                    [emax,df]=fnmin(pp,[0 dfi*2]);
                  end
                  df=min(df,df_lim);
                  if df==0,
                    if g2>0
                      df=dfi*0.9;
                    else
                      df=dfi*1.1;
                    end
                  end
                else
                  if g2>0
                    df=dfi*0.9;
                  else
                    df=dfi*1.1;
                  end
                end
                
              elseif e2>e
                
                %%%%%%%%%%%%%%%%%%%%%%%
                % no decrease in energy
                %%%%%%%%%%%%%%%%%%%%%%%
                
                fprintf('reset search direction, ')
                
                % new search direction
                [dnu_q,dtau_q]=ep_update_dir(mf,Sf,m_r,V_r,eta,up_mode,tolUpdate);
                
                % initial gradient in the search direction
                g = sum( (mf -m_r).*dnu_q ) +0.5*sum( (V_r +m_r.^2 -diag(Sf) -mf.^2).*dtau_q );
                
                % re-init step size adjustment record
                rec_sadj=[0 e g];
              else
                
                dInner=abs(e-e2);
                
                % accept the new state
                [mf,Sf,nu_q,tau_q,lnZ_q]=deal(mf2,Sf2,nu_q2,tau_q2,lnZ_q2);
                [lnZ_i,Z_i,m_r,V_r,e,ec]=deal(lnZ_i2,Z_i2,m_r2,V_r2,e2,ec2);
                
                % check the new cavity variances
                tau_s2=1./diag(Sf);
                cpos=all( (tau_s2-eta.*tau_q )>=tauc_min);
                
                if cpos && (dInner<tolInner || ec<tolInner ||ninner>=max_ninner)
                  
                  %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
                  % update the surrogate distribution
                  ninner=0;
                  nu_s=mf.*tau_s2;
                  tau_s=tau_s2;
                  
                  lnZ_s=0.5*sum( (-log(tau_s) +nu_s.^2 ./tau_s)./eta );
                  
                  % update the tilted distribution
                  [lnZ_i,Z_i,m_r,V_r]=evaluate_r(nu_q,tau_q,eta,fh_tm,nu_s,tau_s);
                  
                  % evaluate new energy
                  e_old=e;
                  e = lnZ_q + lnZ_i -lnZ_s;
                  
                  % new expectation consistency
                  ec = fh_ec(mf,diag(Sf),m_r,V_r);
                  
                  % new search direction
                  %d1=sum(dnu_q.^2)+sum(dtau_q.^2);
                  [dnu_q,dtau_q]=ep_update_dir(mf,Sf,m_r,V_r,eta,up_mode,tolUpdate);
                  
                  % initial gradient in the search direction
                  g = sum( (mf -m_r).*dnu_q ) +0.5*sum( (V_r +m_r.^2 -diag(Sf) -mf.^2).*dtau_q );
                  
                  % update convergence criteria
                  tol_e=abs(e-e_old);
                  tol_ec=ec;
                  
                  fprintf('surrogate update,       ')
                  
                elseif ~cpos && (dInner<tolInner || ec<tolInner ||ninner>=max_ninner)
                  
                  %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
                  % update the surrogate distribution only partially
                  ninner=0;
                  
                  if dInner<tolInner
                    fprintf('switching to fEP, tau_c<tauc_min, ')
                    eta=repmat(0.5,n,1);
                    %               if all( (tau_s2-eta.*tau_q )>=tauc_min)
                    %                 tau_s=tau_s2;
                    %                 nu_s=mf.*tau_s2;
                    %                 fprintf('surrogate update, ')
                    %               end
                    
                  else
                    fprintf('no surrogate update, tau_c<tauc_min, ')
                  end
                  
                  lnZ_s=0.5*sum( (-log(tau_s) +nu_s.^2 ./tau_s)./eta );
                  
                  % update the tilted distribution
                  [lnZ_i,Z_i,m_r,V_r]=evaluate_r(nu_q,tau_q,eta,fh_tm,nu_s,tau_s);
                  
                  % evaluate new energy
                  e_old=e;
                  e = lnZ_q + lnZ_i -lnZ_s;
                  
                  % new expectation consistency
                  %ec = fh_ec(mf,diag(Sf),m_r,V_r);
                  
                  % the new search direction
                  [dnu_q,dtau_q]=ep_update_dir(mf,Sf,m_r,V_r,eta,up_mode,tolUpdate);
                  
                  % initial gradient in the search direction
                  g = sum( (mf -m_r).*dnu_q ) +0.5*sum( (V_r +m_r.^2 -diag(Sf) -mf.^2).*dtau_q );
                  
                else
                  %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
                  % continue with the same surrogate distribution
                  ninner=ninner+1;
                  
                  % new search direction
                  [dnu_q,dtau_q]=ep_update_dir(mf,Sf,m_r,V_r,eta,up_mode,tolUpdate);
                  
                  % initial gradient in the search direction
                  g = sum( (mf -m_r).*dnu_q ) +0.5*sum( (V_r +m_r.^2 -diag(Sf) -mf.^2).*dtau_q );
                  
                  fprintf('no surrogate update,    ')
                end
                
                % re-init step size adjustment record
                rec_sadj=[0 e g];
              end
              
              %maxds=[max(abs(dnu_q)) max(abs(dtau_q))];
              maxds=[max(abs(mf-m_r)) max(abs(diag(Sf)-V_r))];
              
              fprintf('%d, e=%.6f, dm=%.4f, dV=%.4f, df=%6f, df_con=%d\n',i1,e,maxds(1),maxds(2),df,df_con)
              
              %%%%%%%%%%%%%%%%%%%%%%%
              % Check for convergence
              if tol_e<tolStop
                break
              end
            end % end of site iterations
          end % end of verified updates
          
          if ~isfinite(e)
            e=1e6;
%             keyboard
          end
          
          edata=-e;
          
          % =====================================================================================
          % Evaluate the prior contribution to the error from covariance functions and likelihood
          % =====================================================================================
          
          % Evaluate the prior contribution to the error from covariance functions
          eprior = 0;
          for i=1:ncf
            gpcf = gp.cf{i};
            eprior = eprior - gpcf.fh.lp(gpcf);
            %         eprior = eprior - feval(gpcf.fh.lp, gpcf, x, y);
          end
          
          % Evaluate the prior contribution to the error from likelihood functions
          if isfield(gp, 'lik') && isfield(gp.lik, 'p')
            likelih = gp.lik;
            eprior = eprior - likelih.fh.lp(likelih);
          end
          
          e = edata + eprior;
          sigm2vec_i = (tau_s-eta.*tau_q).^-1;
          muvec_i = (nu_s-eta.*nu_q).*sigm2vec_i;
          [L, notpositivedefinite] = chol(Sf);
          if notpositivedefinite
            [e, edata, eprior, tautilde, nutilde, L, La2, b, muvec_i, sigm2vec_i, Z_i, eta, ch] = set_output_for_notpositivedefinite();
            return
          end
          La2 = [];
          b = [];
          nutilde = nu_q;
          tautilde = tau_q;
          
          % store values to the cache
          ch.w = w;
          ch.e = e;
          ch.edata = edata;
          ch.eprior = eprior;
          %       ch.mf = mf;
          ch.L = L;
          ch.nu_q = nu_q;
          ch.tau_q = tau_q;
          ch.La2 = La2;
          ch.b = b;
          ch.eta = eta;
          ch.Z_i = Z_i;
          ch.sigm2vec_i = sigm2vec_i;
          ch.muvec_i = muvec_i;
          %       ch.maxds = maxds;
          ch.datahash = datahash;
          
        end
      otherwise
        error('Unknown optim method!');
    end
  end
  
    function [m_q,S_q,lnZ_q,L1,L2]=evaluate_q(nu_q,tau_q,K)
      
      %%%%%%%%%%%%%%%%
      % q-distribution
      
      n=length(nu_q);
      ii1=find(tau_q>0); n1=length(ii1); W1=sqrt(tau_q(ii1));
      ii2=find(tau_q<0); n2=length(ii2); W2=sqrt(abs(tau_q(ii2)));
      
      L=zeros(n);
      S_q=K;
      if ~isempty(ii1)
        % Cholesky decomposition for positive sites
        L1=(W1*W1').*K(ii1,ii1);
        L1(1:n1+1:end)=L1(1:n1+1:end)+1;
        L1=chol(L1);
        
        L(:,ii1) = bsxfun(@times,K(:,ii1),W1')/L1;
        
        S_q=S_q-L(:,ii1)*L(:,ii1)';
      else
        L1=1;
      end
      
      if ~isempty(ii2)
        % Cholesky decomposition for negative sites
        V=bsxfun(@times,K(ii2,ii1),W1')/L1;
        L2=(W2*W2').*(V*V'-K(ii2,ii2));
        L2(1:n2+1:end)=L2(1:n2+1:end)+1;
        
        [L2,pd]=chol(L2);
        if pd==0
          L(:,ii2)=bsxfun(@times,K(:,ii2),W2')/L2 -L(:,ii1)*(bsxfun(@times,V,W2)'/L2);
          S_q=S_q+L(:,ii2)*L(:,ii2)';
        else
          L2=[];
          
          fprintf('Negative definite q-distribution.\n')
        end
        
      else
        L2=1;
      end
      %V_q=diag(S_q);
      m_q=S_q*nu_q;
      
      % log normalization
      lnZ_q = -sum(log(diag(L1))) -sum(log(diag(L2))) +0.5*sum(m_q.*nu_q);
    end
    
    function [lnZ_i,Z_i,m_r,V_r,p]=evaluate_r(nu_q,tau_q,eta,fh_tm,nu_s,tau_s)
      
      %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
      % r-distribution (tilted distribution)
      
      n=length(nu_q);
      [m_r,V_r,nu_r,tau_r,p]=deal(zeros(n,1));
      Z_i=ones(n,1);
      for si=1:n
        % cavity distribution
        tau_r_si=tau_s(si)-eta(si)*tau_q(si);
        if tau_r_si<=0
          fprintf('Negative cavity precision at site %d.\n',si)
          continue
        end
        nu_r_si=nu_s(si)-eta(si)*nu_q(si);
        
        % tilted moments
        [Z_i_si,m_r_si,V_r_si] = fh_tm(si, nu_r_si/tau_r_si, 1/tau_r_si, eta(si));
        
        if V_r_si<=0
          fprintf('Negative tilted variance at site %d\n',si)
          continue
        end
        
        % store the new parameters
        [nu_r(si),tau_r(si),Z_i(si),m_r(si),V_r(si)]=...
          deal(nu_r_si,tau_r_si,Z_i_si,m_r_si,V_r_si);
        
        p(si)=1;
      end
      
      lnZ_i=sum(log(Z_i)./eta) +0.5*sum((-log(tau_r) +nu_r.^2 ./tau_r)./eta);
    end
    
    
    
    function [e, edata, eprior, tautilde, nutilde, L, La2, b, muvec_i, sigm2vec_i, Z_i, eta, ch] = set_output_for_notpositivedefinite()
      % Instead of stopping to chol error, return NaN
      e = NaN;
      edata = NaN;
      eprior = NaN;
      tautilde = NaN;
      nutilde = NaN;
      L = NaN;
      La2 = NaN;
      b = NaN;
      muvec_i = NaN;
      sigm2vec_i = NaN;
      Z_i = NaN;
      datahash = NaN;
      eta = NaN;
      w = NaN;
      ch.e = e;
      ch.edata = edata;
      ch.eprior = eprior;
      ch.tautilde = tautilde;
      ch.nutilde = nutilde;
      ch.L = L;
      ch.La2 = La2;
      ch.b = b;
      ch.muvec_i = muvec_i;
      ch.sigm2vec_i = sigm2vec_i;
      ch.Z_i = Z_i;
      ch.eta = eta;
      ch.datahash=datahash;
      ch.w = NaN;
    end
    
    
    function [dnu_q,dtau_q]=ep_update_dir(m_q,S_q,m_r,V_r,eta,up_mode,tolUpdate)
      
      %%%%%%%%%%%%%%%%%%%%%%%%%
      % update direction for EP
      %%%%%%%%%%%%%%%%%%%%%%%%%
      
      V_q=diag(S_q);
      switch up_mode
        case 'ep'
          %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
          % site update by moment matching
          [dnu_q,dtau_q]=deal(zeros(size(m_q)));
          
          ind_up=V_r>0 & max(abs(V_r-V_q),abs(m_r-m_q))>tolUpdate;
          
          dnu_q(ind_up) = ( m_r(ind_up)./V_r(ind_up) - m_q(ind_up)./V_q(ind_up) ) ./ eta(ind_up);
          dtau_q(ind_up) = ( 1./V_r(ind_up) - 1./V_q(ind_up) )./ eta(ind_up);
          
        case 'grad'
          %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
          % gradient descend
          
          % evaluate the gradients
          gnu_q = m_q - m_r;
          gtau_q = 0.5*(V_r + m_r.^2 - V_q - m_q.^2);
          
          dnu_q=-gnu_q;
          dtau_q=-gtau_q;
          
          %dfi=1e-1;
          %dnu_q=-dfi*gnu_q;
          %dtau_q=-dfi*gtau_q;
          %[e2,gnu_q2,gtau_q2]=epdl_e(nu_q+dnu_q,tau_q+dtau_q,fh_tm,eta,K,nu_s,tau_s);
          
          % quasi Newton
          %Hnu=(gnu_q2-gnu_q)./dnu_q;
          %Htau=(gtau_q2-gtau_q)./(dtau_q);
          %dnu_q=-gnu_q./(Hnu+a);
          %dtau_q=-gtau_q./(Htau+a);
      end
      
    end
    

end