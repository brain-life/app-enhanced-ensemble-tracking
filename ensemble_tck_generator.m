function ensemble_tck_generator()

switch getenv('ENV')
case 'IUHPC'
  disp('loading paths (HPC)')
  addpath(genpath('/N/u/hayashis/BigRed2/git/vistasoft'))
case 'VM'
  disp('loading paths (VM)')
  addpath(genpath('/usr/local/vistasoft'))
end

% find all the .tck files
ens = dir('output/*.tck');

% pull all the file names
ens_names = {ens.name};

%assignments = cell(length(ens_names), 2);

% loop over and import all the ensemble connectomes
ens_fg = dtiImportFibersMrtrix(char(ens_names(1)), .5);

for ii = 2:length(ens_names)
  
  % import the new streamlines                                  
  tfg = dtiImportFibersMrtrix(char(ens_names(ii)), .5);
                                               
  % append the new streamlines to the fiber group
  ens_fg.fibers = [ ens_fg.fibers; tfg.fibers ];

  % catch assignment order
  %assignments{ii, 1} = ens_names{ii};
  %assignments{ii, 2} = size(tfg.fibers, 1);
  
end

% save out
dtiExportFibersMrtrix(ens_fg, 'output/ensemble.tck')
%save('assignments.mat', 'assignments');

end

